package routepolicy

import (
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// spec 只取契约里与本包有关的部分：paths 下每个路径的方法与 security 声明。
// 方法先落成节点再解码，因为同一层还可能有 path 级的 parameters 序列。
type spec struct {
	Paths map[string]map[string]yaml.Node `yaml:"paths"`
}

// operation 保留 security 节点而不是解码成切片，是为了区分“没写 security”
// （继承文件顶部的全局 bearer）与“写了 security: []”（显式公开）。
type operation struct {
	Security yaml.Node `yaml:"security"`
}

var httpMethods = map[string]bool{
	http.MethodGet:     true,
	http.MethodHead:    true,
	http.MethodPost:    true,
	http.MethodPut:     true,
	http.MethodPatch:   true,
	http.MethodDelete:  true,
	http.MethodOptions: true,
	http.MethodTrace:   true,
}

// TestPublicOperationsMatchSpec 保证代码里的公开操作表与 openapi.yaml 的
// security: [] 完全一致：两边任何一侧新增、删除或改名都会失败。契约是接口的
// 唯一真相，鉴权默认拒绝的清单不能靠记忆维护。
func TestPublicOperationsMatchSpec(t *testing.T) {
	specPublic, specAll := specOperations(t)

	codePublic := map[string]bool{}
	for _, pattern := range PublicOperations() {
		codePublic[pattern] = true
	}

	// 两边的集合必须相同，且每一条都要指得出来。
	for _, pattern := range sortedKeys(specPublic) {
		if !codePublic[pattern] {
			t.Errorf("契约声明公开但 PublicOperations 没有列出：%s", pattern)
		}
	}
	for _, pattern := range sortedKeys(codePublic) {
		if !specPublic[pattern] {
			t.Errorf("PublicOperations 列为公开但契约没有 security: []：%s", pattern)
		}
	}
	// 其余操作一律要求鉴权：契约新增受保护接口时不需要改代码也能守住。
	for _, pattern := range sortedKeys(specAll) {
		if specPublic[pattern] {
			if RequiresAuth(pattern) {
				t.Errorf("公开操作 %s 被判定为需要鉴权", pattern)
			}
			continue
		}
		if !RequiresAuth(pattern) {
			t.Errorf("契约要求鉴权的操作 %s 被放行了", pattern)
		}
	}
}

func TestCloudWritePoliciesMatchContract(t *testing.T) {
	_, all := specOperations(t)
	for pattern := range all {
		method, path, _ := strings.Cut(pattern, " ")
		cloud := path == "/v1/backups" || strings.HasPrefix(path, "/v1/backups/") ||
			strings.HasPrefix(path, "/v1/blobs/") || strings.HasPrefix(path, "/v1/sync/") ||
			path == "/v1/cloud" || pattern == "DELETE /v1/me"
		mutates := method == http.MethodPost || method == http.MethodPut ||
			method == http.MethodPatch || method == http.MethodDelete
		if _, ok := CloudWritePolicy(pattern); ok != (cloud && mutates) {
			t.Errorf("%s: unexpected cloud write coverage %v", pattern, ok)
		}
	}
	wantUpload := map[string]Spool{
		"POST /v1/backups":       BackupSpool,
		"PUT /v1/blobs/{sha256}": AttachmentSpool,
		"POST /v1/sync/commits":  NoSpool,
	}
	for pattern, policy := range cloudWrites {
		if !all[pattern] {
			t.Errorf("%s: cloud write policy has no operation in OpenAPI", pattern)
		}
		spool, upload := wantUpload[pattern]
		if IsUpload(pattern) != upload || policy.Spool != spool {
			t.Errorf("%s: upload=%v spool=%v, want upload=%v spool=%v", pattern, policy.Upload, policy.Spool, upload, spool)
		}
		if policy.Exclusive && policy.Upload {
			t.Errorf("%s: exclusive deletion also marked as upload", pattern)
		}
	}
}

// TestRosterWritesMatchContract 守住“会写名册的读接口”清单：每一条都要在契约里、
// 是 GET、并且要求鉴权——它们只有落到具体账号上才有名册可写。
func TestRosterWritesMatchContract(t *testing.T) {
	public, all := specOperations(t)
	if len(rosterWrites) == 0 {
		t.Fatal("rosterWrites 不应为空")
	}
	for pattern := range rosterWrites {
		if !all[pattern] {
			t.Errorf("契约里没有 %s", pattern)
			continue
		}
		if !strings.HasPrefix(pattern, http.MethodGet+" ") {
			t.Errorf("%s 不是读接口", pattern)
		}
		if public[pattern] {
			t.Errorf("%s 是公开操作，不应写名册", pattern)
		}
		if _, ok := CloudWritePolicy(pattern); ok {
			t.Errorf("%s 同时被列为云端写操作", pattern)
		}
	}
}

func TestCacheOperationsAreExplicit(t *testing.T) {
	if seconds, ok := CacheSeconds("GET /v1/app/releases"); !ok || seconds <= 0 {
		t.Fatalf("发布清单应当可以缓存，得到 %d, %v", seconds, ok)
	}
	if _, ok := CacheSeconds("GET /v1/me"); ok {
		t.Fatal("账号接口不能被缓存")
	}
	// 可缓存的响应同时必须是公开的：账号相关的响应不能进中间层缓存。
	for pattern := range cacheableOperations {
		if !IsPublic(pattern) {
			t.Errorf("可缓存操作 %s 不是公开操作", pattern)
		}
	}
}

func sortedKeys(set map[string]bool) []string {
	keys := make([]string, 0, len(set))
	for key := range set {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// specOperations 解析契约里的全部操作，并分出显式公开的那些。
func specOperations(t *testing.T) (public, all map[string]bool) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "api", "openapi.yaml"))
	if err != nil {
		t.Fatalf("读取契约：%v", err)
	}
	var doc spec
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("解析契约：%v", err)
	}
	public = map[string]bool{}
	all = map[string]bool{}
	for path, operations := range doc.Paths {
		for method, node := range operations {
			method = strings.ToUpper(method)
			if !httpMethods[method] {
				// parameters 之类的路径级键不是操作。
				continue
			}
			var op operation
			if err := node.Decode(&op); err != nil {
				t.Fatalf("解析 %s %s 的 security 声明：%v", method, path, err)
			}
			pattern := method + " " + path
			all[pattern] = true
			if op.Security.Kind == yaml.SequenceNode && len(op.Security.Content) == 0 {
				public[pattern] = true
			}
		}
	}
	if len(all) == 0 {
		t.Fatal("契约里没有解析出任何操作，检查 openapi.yaml 的格式或路径")
	}
	return public, all
}

// TestKeyOperationsAreModelEndpointsOnly 守住模型代理密钥的作用域：只收 /v1/llm
// 下的模型接口，契约里确实存在，且不是公开操作；账号、同步与备份接口都不接受
// 密钥（ADR-0063）。
func TestKeyOperationsAreModelEndpointsOnly(t *testing.T) {
	public, all := specOperations(t)
	if len(KeyOperations()) == 0 {
		t.Fatal("keyOperations 不应为空")
	}
	for _, pattern := range KeyOperations() {
		if !all[pattern] {
			t.Errorf("契约里没有 %s", pattern)
		}
		if public[pattern] {
			t.Errorf("%s 是公开操作，不应在密钥作用域里", pattern)
		}
		if !strings.HasPrefix(pattern, "GET /v1/llm/") && !strings.HasPrefix(pattern, "POST /v1/llm/") {
			t.Errorf("密钥只应调用模型接口，%s 不在 /v1/llm 下", pattern)
		}
	}
	for _, pattern := range []string{
		"POST /v1/me/api-keys",
		"GET /v1/me/api-keys",
		"DELETE /v1/me/api-keys",
		"DELETE /v1/me/api-keys/{id}",
		"GET /v1/sync/head",
		"POST /v1/backups",
		"DELETE /v1/cloud",
	} {
		if AllowsKey(pattern) {
			t.Errorf("%s 不应接受模型代理密钥", pattern)
		}
	}
}
