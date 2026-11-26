package pg

import (
	"context"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// 管理后台按密钥的对账读取（ADR-0076）：llm_usage 按账号、自然日、用途与密钥
// 分开记，api_key 补上名字、前缀、撤销状态与最近使用时间。左连接保留密钥行被
// 每日清理删除之后的用量。
var _ llmproxy.KeyUsageStore = (*Store)(nil)

func (s *Store) KeyUsage(ctx context.Context, from, to string) ([]llmproxy.KeyUsage, error) {
	start, err := pgDate(from)
	if err != nil {
		return nil, err
	}
	end, err := pgDate(to)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListKeyUsage(ctx, db.ListKeyUsageParams{FromDay: start, ToDay: end})
	if err != nil {
		return nil, err
	}
	out := make([]llmproxy.KeyUsage, 0, len(rows))
	for _, row := range rows {
		usage := llmproxy.KeyUsage{
			Day: row.Day.Time.Format("2006-01-02"), UserID: row.UserID, KeyID: row.ApiKeyID,
			Name: row.KeyName, Prefix: row.KeyPrefix, KeyPresent: row.KeyPresent,
			Revoked: row.Revoked, Kind: llmproxy.Kind(row.Kind),
			KeyUsageCounts: llmproxy.KeyUsageCounts{
				Tokens: row.Tokens, ReservedTokens: row.ReservedTokens,
				InputTokens: row.InputTokens, CachedTokens: row.CachedTokens,
			},
		}
		if row.LastUsedAt.Valid {
			usage.LastUsedAt = row.LastUsedAt.Time
		}
		out = append(out, usage)
	}
	return out, nil
}
