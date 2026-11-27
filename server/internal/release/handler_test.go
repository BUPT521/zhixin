package release

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// testAPI 只接本包的路由；其余路由没有覆盖，被调用时会 panic。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) GetV1AppReleases(w http.ResponseWriter, r *http.Request) { a.h.Releases(w, r) }

func newClient(t *testing.T, entries []Entry) *testutil.Client {
	t.Helper()
	return testutil.NewClient(t, testutil.NewServer(testAPI{h: NewHandler(entries)}))
}

func TestReleasesWithoutManifest(t *testing.T) {
	c := newClient(t, nil)
	resp := c.Do(http.MethodGet, "/v1/app/releases", "", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("没有清单时应返回 200，得到 %d", resp.StatusCode)
	}
	// 空数组而不是 null：客户端不需要为没有发布过的实例另写一个分支。
	if body := string(testutil.ReadBody(t, resp)); body != "{\"releases\":[]}\n" {
		t.Fatalf("空清单的响应体应为空数组，得到 %q", body)
	}
}

func TestReleasesReturnsRequiredFieldsAndOptionalOnesOnlyWhenPresent(t *testing.T) {
	c := newClient(t, []Entry{
		{
			Platform: "android", Version: "0.2.0", Build: 2,
			URL: "https://example.test/a.apk", SHA256: zeroSHA, Signature: testSignature, Notes: "说明",
		},
		{
			Platform: "android-tablet", Version: "0.1.0", Build: 1,
			URL: "https://example.test/b.apk", SHA256: zeroSHA, Size: 10,
			Signature: testSignature,
		},
	})
	resp := c.Do(http.MethodGet, "/v1/app/releases", "", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("得到 %d", resp.StatusCode)
	}
	var out struct {
		Releases []map[string]any `json:"releases"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Releases) != 2 {
		t.Fatalf("应有 2 条，得到 %d", len(out.Releases))
	}
	first, second := out.Releases[0], out.Releases[1]
	if first["sha256"] != zeroSHA {
		t.Fatalf("sha256 是必填字段，第一条应是零哈希：%v", first)
	}
	if _, ok := first["size"]; ok {
		t.Fatalf("没写大小时不应出现 size：%v", first)
	}
	if first["signature"] != testSignature {
		t.Fatalf("响应必须带签名：%v", first)
	}
	if first["notes"] != "说明" || first["version"] != "0.2.0" || first["build"] != float64(2) {
		t.Fatalf("第一条内容不对：%v", first)
	}
	if second["sha256"] != zeroSHA || second["size"] != float64(10) || second["signature"] != testSignature {
		t.Fatalf("第二条的可选字段不对：%v", second)
	}
}
