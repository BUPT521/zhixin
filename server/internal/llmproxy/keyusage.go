package llmproxy

import (
	"cmp"
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	sharedderef "github.com/BUPT521/zhixin/server/internal/deref"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// 管理后台按密钥的对账视图（ADR-0076）。这里只读 llm_usage 与 api_key 两张表，
// 不参与额度判定与核销：按账号额度、积分比例与失败结算的口径不因为这次展示而
// 改变。后台要看的是“哪把密钥用了多少计费 token、大约折成多少积分、还有多少
// 在途预留”，对账之后再去看 account 或即刻收的流水。

// KeyUsageCounts 是一把密钥在一天里的用量。Tokens 是已结算的计费 token，
// ReservedTokens 是还没有结算的在途预留；InputTokens 与 CachedTokens 是上游
// 报告的原始输入量与其中命中缓存的部分，只用于核对缓存命中比例。Attempts 是这
// 一天的尝试次数，Failures 是其中失败、按 0 结算的次数：失败不产生 token，后台
// 要看见“一直在失败”只能看这两项（ADR-0083）。
type KeyUsageCounts struct {
	Tokens         int64
	ReservedTokens int64
	InputTokens    int64
	CachedTokens   int64
	Attempts       int64
	Failures       int64
}

func (c *KeyUsageCounts) add(other KeyUsageCounts) {
	c.Tokens += other.Tokens
	c.ReservedTokens += other.ReservedTokens
	c.InputTokens += other.InputTokens
	c.CachedTokens += other.CachedTokens
	c.Attempts += other.Attempts
	c.Failures += other.Failures
}

func (c KeyUsageCounts) view() api.AdminKeyUsageCounts {
	return api.AdminKeyUsageCounts{
		Tokens: c.Tokens, ReservedTokens: c.ReservedTokens,
		InputTokens: c.InputTokens, CachedTokens: c.CachedTokens,
		Attempts: c.Attempts, Failures: c.Failures,
	}
}

// KeyUsage 是一行按账号、密钥、自然日与用途分开记的用量。KeyID 为空字符串表示
// 这次调用用的是访问令牌；KeyPresent 为假表示 api_key 行已经被每日清理删除，用量
// 行仍然保留，名字为空。名字为空的在用密钥与已清理的密钥只能靠 KeyPresent 区分，
// 不能只看名字。
type KeyUsage struct {
	Day           string
	UserID, KeyID string
	Name, Prefix  string
	KeyPresent    bool
	Revoked       bool
	LastUsedAt    time.Time
	Kind          Kind
	KeyUsageCounts
}

// KeyUsageStore 是管理后台对账用到的可选能力。它不放进 Quota：额度接口的语义是
// 判定与扣减，读历史用量是另一件事，缺少实现时后台只关掉这一个视图。
type KeyUsageStore interface {
	KeyUsage(ctx context.Context, from, to, userID string) ([]KeyUsage, error)
}

// KeyUsage 汇总区间内按密钥分开记的用量。参数与 /admin/v1/usage 相同：days 含
// 今天，按服务端时区计算。响应里的 tokens_per_point 与核销同一配置，后台据此把
// 聊天和嵌入的计费 token 合计折成参考积分，各用途的用量仍单独列出。
func (a *Admin) KeyUsage(w http.ResponseWriter, r *http.Request, params api.GetAdminV1KeyUsageParams) {
	days := sharedderef.Value(params.Days, 7)
	if days < 1 || days > 30 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "days: 1 to 30")
		return
	}
	userID := strings.TrimSpace(sharedderef.Value(params.UserId, ""))
	if params.UserId != nil && (userID == "" || len(userID) > 128) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "user_id: 1 to 128 bytes")
		return
	}
	store, ok := a.proxy.quota.(KeyUsageStore)
	if !ok {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "key usage storage is not configured")
		return
	}
	today := a.proxy.dayTime()
	first := today.AddDate(0, 0, 1-days)
	const dateFormat = "2006-01-02"
	rows, err := store.KeyUsage(r.Context(), first.Format(dateFormat), today.Format(dateFormat), userID)
	if err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, fmt.Errorf("read key usage: %w", err))
		return
	}

	// 一个账号的访问令牌调用没有 api_key 行，按 (账号, 空密钥编号) 单独成一行；
	// 同一把密钥在各天的行在这里合并，日表留给页面做趋势。
	type keyID struct{ userID, keyID string }
	type dayCounts struct{ chat, embedding KeyUsageCounts }
	type aggregate struct {
		chat, embedding  KeyUsageCounts
		daily            map[string]dayCounts
		name, prefix     string
		present, revoked bool
		lastUsed         time.Time
	}
	byKey := make(map[keyID]*aggregate)
	for _, row := range rows {
		id := keyID{userID: row.UserID, keyID: row.KeyID}
		agg := byKey[id]
		if agg == nil {
			agg = &aggregate{daily: make(map[string]dayCounts)}
			byKey[id] = agg
		}
		// 名字与撤销状态来自同一条 api_key 行；已清理的密钥没有名字，保留空字符串
		// 让页面显示“已清理”，不要拿密钥编号冒充名字。行是否还在单独记在
		// key_present 上：名字为空的在用密钥同样不带名字，只看名字分不出两者。
		if row.KeyPresent {
			agg.name, agg.prefix = row.Name, row.Prefix
		}
		agg.present = agg.present || row.KeyPresent
		agg.revoked = agg.revoked || row.Revoked
		if row.LastUsedAt.After(agg.lastUsed) {
			agg.lastUsed = row.LastUsedAt
		}
		day := agg.daily[row.Day]
		if row.Kind == KindEmbedding {
			agg.embedding.add(row.KeyUsageCounts)
			day.embedding.add(row.KeyUsageCounts)
		} else {
			agg.chat.add(row.KeyUsageCounts)
			day.chat.add(row.KeyUsageCounts)
		}
		agg.daily[row.Day] = day
	}

	out := api.AdminKeyUsageReport{
		Timezone:       today.Location().String(),
		FromDay:        openapi_types.Date{Time: first},
		ToDay:          openapi_types.Date{Time: today},
		TokensPerPoint: a.proxy.cfg.TokensPerPoint,
		Keys:           make([]api.AdminKeyUsage, 0, len(byKey)),
	}
	for id, agg := range byKey {
		view := api.AdminKeyUsage{
			KeyId: id.keyID, UserId: id.userID, Name: agg.name, Prefix: agg.prefix,
			KeyPresent: agg.present, Revoked: agg.revoked, Chat: agg.chat.view(), Embedding: agg.embedding.view(),
			Daily: make(map[string]api.AdminKeyUsageDay, len(agg.daily)),
		}
		if !agg.lastUsed.IsZero() {
			at := agg.lastUsed
			view.LastUsedAt = &at
		}
		for day, counts := range agg.daily {
			view.Daily[day] = api.AdminKeyUsageDay{Chat: counts.chat.view(), Embedding: counts.embedding.view()}
		}
		out.Keys = append(out.Keys, view)
	}
	slices.SortFunc(out.Keys, func(a, b api.AdminKeyUsage) int {
		return cmp.Or(
			cmp.Compare(b.Chat.Tokens, a.Chat.Tokens),
			cmp.Compare(b.Embedding.Tokens, a.Embedding.Tokens),
			cmp.Compare(a.UserId, b.UserId),
			cmp.Compare(a.KeyId, b.KeyId),
		)
	})
	httpx.WriteJSON(w, http.StatusOK, out)
}

// SetKeyLookup connects the development quota store to its in-memory account store.
func (m *MemoryQuota) SetKeyLookup(keysByUser func(context.Context, string) ([]auth.APIKey, error)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.keysByUser = keysByUser
}

// KeyUsage 读取内存账本中的已结算量、预留、上报量与尝试次数。
func (m *MemoryQuota) KeyUsage(ctx context.Context, from, to, userID string) ([]KeyUsage, error) {
	m.mu.Lock()
	var out []KeyUsage
	for key, row := range m.usage {
		if key.day < from || key.day > to || (userID != "" && key.userID != userID) {
			continue
		}
		out = append(out, KeyUsage{
			Day: key.day, UserID: key.userID, KeyID: key.keyID, Kind: key.kind, KeyUsageCounts: row.KeyUsageCounts,
		})
	}
	readKeys := m.keysByUser
	m.mu.Unlock()

	if readKeys != nil {
		keysByAccount := make(map[string]map[string]auth.APIKey)
		for i := range out {
			row := &out[i]
			if row.KeyID == "" {
				continue
			}
			keys, loaded := keysByAccount[row.UserID]
			if !loaded {
				records, err := readKeys(ctx, row.UserID)
				if err != nil {
					return nil, err
				}
				keys = make(map[string]auth.APIKey, len(records))
				for _, record := range records {
					keys[record.ID] = record
				}
				keysByAccount[row.UserID] = keys
			}
			if key, present := keys[row.KeyID]; present {
				row.Name, row.Prefix = key.Name, key.Prefix
				row.KeyPresent, row.Revoked = true, !key.RevokedAt.IsZero()
				row.LastUsedAt = key.LastUsedAt
			}
		}
	}
	slices.SortFunc(out, func(a, b KeyUsage) int {
		return cmp.Or(cmp.Compare(a.Day, b.Day), cmp.Compare(a.UserID, b.UserID),
			cmp.Compare(a.KeyID, b.KeyID), cmp.Compare(a.Kind, b.Kind))
	})
	return out, nil
}
