package llmproxy

import (
	"cmp"
	"context"
	"fmt"
	"net/http"
	"slices"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
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
	KeyUsage(ctx context.Context, from, to string) ([]KeyUsage, error)
}

// KeyUsage 汇总区间内按密钥分开记的用量。参数与 /admin/v1/usage 相同：days 含
// 今天，按服务端时区计算。响应里的 tokens_per_point 与核销同一配置，后台据此把
// 对话的计费 token 折成积分；嵌入不参与积分，单独列出，避免把它折进金额。
func (a *Admin) KeyUsage(w http.ResponseWriter, r *http.Request, params api.GetAdminV1KeyUsageParams) {
	days := deref(params.Days, 7)
	if days < 1 || days > 30 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "days: 1 to 30")
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
	rows, err := store.KeyUsage(r.Context(), first.Format(dateFormat), today.Format(dateFormat))
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
		if row.Name != "" {
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

// KeyUsage 在内存实现里从已结算、在途预留与尝试计数三张表拼出对账视图。缓存命中
// 的原始输入只在最近一次结算里留了一份（Split），这里不拿它冒充累计值，
// InputTokens 与 CachedTokens 保持 0；本地联调看到的趋势与总量仍然与额度判定一致。
// 只有尝试记录、token 与预留都是 0 的行也返回：那正是一次失败的调用，过滤掉它
// 之后一把一直在失败的密钥在后台看起来与没有用过的一样（ADR-0083）。
func (m *MemoryQuota) KeyUsage(_ context.Context, from, to string) ([]KeyUsage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	type rowKey struct{ userID, day, kind, keyID string }
	rows := make(map[rowKey]*KeyUsage)
	get := func(k [4]string) *KeyUsage {
		id := rowKey{userID: k[0], day: k[1], kind: k[2], keyID: k[3]}
		row := rows[id]
		if row == nil {
			row = &KeyUsage{Day: k[1], UserID: k[0], KeyID: k[3], Kind: Kind(k[2])}
			rows[id] = row
		}
		return row
	}
	for k, tokens := range m.used {
		if k[1] < from || k[1] > to {
			continue
		}
		get(k).Tokens += tokens
	}
	for k, reserved := range m.reserved {
		if k[1] < from || k[1] > to {
			continue
		}
		get(k).ReservedTokens += reserved
	}
	for k, attempts := range m.attempts {
		if k[1] < from || k[1] > to {
			continue
		}
		get(k).Attempts += attempts
	}
	for k, failures := range m.failures {
		if k[1] < from || k[1] > to {
			continue
		}
		get(k).Failures += failures
	}
	out := make([]KeyUsage, 0, len(rows))
	for _, row := range rows {
		out = append(out, *row)
	}
	slices.SortFunc(out, func(a, b KeyUsage) int {
		return cmp.Or(cmp.Compare(a.Day, b.Day), cmp.Compare(a.UserID, b.UserID),
			cmp.Compare(a.KeyID, b.KeyID), cmp.Compare(a.Kind, b.Kind))
	})
	return out, nil
}
