package llmproxy

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// Kind 区分对外模型的用途：聊天走 /chat/completions，嵌入走 /embeddings。
type Kind string

const (
	KindChat      Kind = "chat"
	KindEmbedding Kind = "embedding"
)

// EnvProviderID 是环境变量生成的只读来源的编号，管理后台不能用这个名字。
const EnvProviderID = "env"

var (
	// ErrNotFound 表示来源或模型不存在。
	ErrNotFound = errors.New("llmproxy: not found")
	// ErrProviderInUse 表示还有模型路由指向这个来源，不能删除。
	ErrProviderInUse = errors.New("llmproxy: provider is referenced by model routes")
	// ErrUnknownProvider 表示路由指向一个不存在的来源。
	ErrUnknownProvider = errors.New("llmproxy: route references an unknown provider")
)

// ProviderRecord 是存储里的一个模型来源：一个 OpenAI 兼容的基础地址与一把
// key。key 只以密文保存（secretbox），明文只在路由快照里出现。
type ProviderRecord struct {
	ID           string
	Name         string
	BaseURL      string
	APIKeySealed string
	// KeyHint 是 key 的末四位，保存时算好，列表不需要解密。
	KeyHint   string
	Enabled   bool
	Note      string
	UpdatedAt time.Time
}

// Route 把一个对外模型指到某个来源上的一个模型名。
type Route struct {
	ProviderID    string
	UpstreamModel string
	// Priority 小的先试；同一优先级内按 Weight 随机分流。
	Priority int
	Weight   int
	// MaxBatch 是嵌入时一次发给来源的最多条数，0 表示不拆分。
	MaxBatch int
	Enabled  bool
}

// ModelRecord 是客户端看到的一个模型名与它的全部路由。
type ModelRecord struct {
	Name       string
	Kind       Kind
	Enabled    bool
	Dimensions int // 0 表示没有配置；只用于嵌入模型
	Note       string
	Routes     []Route
	UpdatedAt  time.Time
}

// Catalog 保存管理后台配置的来源与模型。PutModel 整体替换路由；DeleteProvider
// 在还有路由指向时返回 ErrProviderInUse，由管理员先改模型。
type Catalog interface {
	Providers(ctx context.Context) ([]ProviderRecord, error)
	Provider(ctx context.Context, id string) (ProviderRecord, error)
	PutProvider(ctx context.Context, p ProviderRecord) error
	DeleteProvider(ctx context.Context, id string) error
	Models(ctx context.Context) ([]ModelRecord, error)
	PutModel(ctx context.Context, m ModelRecord) error
	DeleteModel(ctx context.Context, name string) error
}

var (
	providerIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)
	modelNamePattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`)
)

// KeyAAD 是加密来源 key 时的附加数据：来源编号加上地址的协议与主机。密文
// 因此绑定在这个来源与这台主机上，直接改库把地址换成别的主机时 key 无法解密，
// 不会被发到新地址；同一主机下改路径不受影响。
func KeyAAD(id, baseURL string) string {
	return id + "\n" + origin(baseURL)
}

// origin 返回地址的协议与主机部分，解析失败时返回原样。
func origin(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	return strings.ToLower(u.Scheme + "://" + u.Host)
}

// ValidProviderID 报告来源编号是否合法；env 留给环境变量。
func ValidProviderID(id string) bool {
	return providerIDPattern.MatchString(id) && id != EnvProviderID
}

// ValidModelName 报告对外模型名是否合法。不允许斜杠，因为它要出现在管理接口
// 的路径里；来源侧的模型名（例如 BAAI/bge-m3）不受这个限制。
func ValidModelName(name string) bool { return modelNamePattern.MatchString(name) }

// MemoryCatalog 是进程内的 Catalog，用于本地联调与测试。
type MemoryCatalog struct {
	mu        sync.Mutex
	providers map[string]ProviderRecord
	models    map[string]ModelRecord
}

func NewMemoryCatalog() *MemoryCatalog {
	return &MemoryCatalog{providers: map[string]ProviderRecord{}, models: map[string]ModelRecord{}}
}

func (m *MemoryCatalog) Providers(context.Context) ([]ProviderRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]ProviderRecord, 0, len(m.providers))
	for _, p := range m.providers {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (m *MemoryCatalog) Provider(_ context.Context, id string) (ProviderRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.providers[id]
	if !ok {
		return ProviderRecord{}, ErrNotFound
	}
	return p, nil
}

func (m *MemoryCatalog) PutProvider(_ context.Context, p ProviderRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.providers[p.ID] = p
	return nil
}

func (m *MemoryCatalog) DeleteProvider(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.providers[id]; !ok {
		return ErrNotFound
	}
	for _, model := range m.models {
		for _, r := range model.Routes {
			if r.ProviderID == id {
				return ErrProviderInUse
			}
		}
	}
	delete(m.providers, id)
	return nil
}

func (m *MemoryCatalog) Models(context.Context) ([]ModelRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]ModelRecord, 0, len(m.models))
	for _, model := range m.models {
		model.Routes = slices.Clone(model.Routes)
		out = append(out, model)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func (m *MemoryCatalog) PutModel(_ context.Context, model ModelRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, r := range model.Routes {
		if _, ok := m.providers[r.ProviderID]; !ok {
			return ErrUnknownProvider
		}
	}
	model.Routes = slices.Clone(model.Routes)
	m.models[model.Name] = model
	return nil
}

func (m *MemoryCatalog) DeleteModel(_ context.Context, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.models[name]; !ok {
		return ErrNotFound
	}
	delete(m.models, name)
	return nil
}

// ModelsUsingProvider 列出路由指向某个来源的模型名，供删除被拒时提示。
func ModelsUsingProvider(models []ModelRecord, providerID string) []string {
	var names []string
	for _, m := range models {
		for _, r := range m.Routes {
			if r.ProviderID == providerID {
				names = append(names, m.Name)
				break
			}
		}
	}
	return names
}
