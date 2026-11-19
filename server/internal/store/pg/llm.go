package pg

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

var _ llmproxy.Catalog = (*Store)(nil)

func providerFromRow(r db.LlmProvider) llmproxy.ProviderRecord {
	return llmproxy.ProviderRecord{
		ID: r.ID, Name: r.Name, BaseURL: r.BaseUrl,
		APIKeySealed: r.ApiKeySealed, KeyHint: r.KeyHint,
		Enabled: r.Enabled, Note: r.Note, UpdatedAt: r.UpdatedAt.Time,
	}
}

// Providers 列出管理后台保存的模型来源。
func (s *Store) Providers(ctx context.Context) ([]llmproxy.ProviderRecord, error) {
	rows, err := s.q.ListLLMProviders(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]llmproxy.ProviderRecord, 0, len(rows))
	for _, r := range rows {
		out = append(out, providerFromRow(r))
	}
	return out, nil
}

// Provider 读取一个来源；不存在时返回 llmproxy.ErrNotFound。
func (s *Store) Provider(ctx context.Context, id string) (llmproxy.ProviderRecord, error) {
	r, err := s.q.GetLLMProvider(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return llmproxy.ProviderRecord{}, llmproxy.ErrNotFound
	}
	if err != nil {
		return llmproxy.ProviderRecord{}, err
	}
	return providerFromRow(r), nil
}

// PutProvider 新建或覆盖一个来源。
func (s *Store) PutProvider(ctx context.Context, p llmproxy.ProviderRecord) error {
	at, err := pgTime(p.UpdatedAt)
	if err != nil {
		return err
	}
	return s.q.UpsertLLMProvider(ctx, db.UpsertLLMProviderParams{
		ID: p.ID, Name: p.Name, BaseUrl: p.BaseURL,
		ApiKeySealed: p.APIKeySealed, KeyHint: p.KeyHint,
		Enabled: p.Enabled, Note: p.Note, UpdatedAt: at,
	})
}

// DeleteProvider 删除一个来源；还有路由指向它时返回 llmproxy.ErrProviderInUse。
// 先数一遍是为了给出明确的错误，外键（不级联）兜住并发写入的情况。
func (s *Store) DeleteProvider(ctx context.Context, id string) error {
	n, err := s.q.CountRoutesForProvider(ctx, id)
	if err != nil {
		return err
	}
	if n > 0 {
		return llmproxy.ErrProviderInUse
	}
	deleted, err := s.q.DeleteLLMProvider(ctx, id)
	if isForeignKeyViolation(err) {
		return llmproxy.ErrProviderInUse
	}
	if err != nil {
		return err
	}
	if deleted == 0 {
		return llmproxy.ErrNotFound
	}
	return nil
}

// Models 列出对外模型与各自的路由，路由按管理后台里的顺序。两条查询放在
// 同一个只读快照事务里，不会读到改了一半的模型与路由。
func (s *Store) Models(ctx context.Context) ([]llmproxy.ModelRecord, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)
	models, err := q.ListLLMModels(ctx)
	if err != nil {
		return nil, err
	}
	routes, err := q.ListLLMRoutes(ctx)
	if err != nil {
		return nil, err
	}
	byModel := map[string][]llmproxy.Route{}
	for _, r := range routes {
		byModel[r.Model] = append(byModel[r.Model], llmproxy.Route{
			ProviderID: r.ProviderID, UpstreamModel: r.UpstreamModel,
			Priority: int(r.Priority), Weight: int(r.Weight), MaxBatch: int(r.MaxBatch),
			Enabled: r.Enabled,
		})
	}
	out := make([]llmproxy.ModelRecord, 0, len(models))
	for _, m := range models {
		out = append(out, llmproxy.ModelRecord{
			Name: m.Name, Kind: llmproxy.Kind(m.Kind), Enabled: m.Enabled,
			Dimensions: int(m.Dimensions.Int32), Note: m.Note, UpdatedAt: m.UpdatedAt.Time,
			Routes: byModel[m.Name],
		})
	}
	return out, nil
}

// PutModel 在一个事务里写模型并整体替换它的路由。路由指向不存在的来源时
// 返回 llmproxy.ErrUnknownProvider。
func (s *Store) PutModel(ctx context.Context, m llmproxy.ModelRecord) error {
	at, err := pgTime(m.UpdatedAt)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	var dims pgtype.Int4
	if m.Dimensions > 0 {
		dims = pgtype.Int4{Int32: int32(m.Dimensions), Valid: true}
	}
	if err := q.UpsertLLMModel(ctx, db.UpsertLLMModelParams{
		Name: m.Name, Kind: string(m.Kind), Enabled: m.Enabled,
		Dimensions: dims, Note: m.Note, UpdatedAt: at,
	}); err != nil {
		return err
	}
	if err := q.DeleteLLMRoutesForModel(ctx, m.Name); err != nil {
		return err
	}
	for i, r := range m.Routes {
		err := q.InsertLLMRoute(ctx, db.InsertLLMRouteParams{
			Model: m.Name, ProviderID: r.ProviderID, UpstreamModel: r.UpstreamModel,
			Priority: int32(r.Priority), Weight: int32(r.Weight), MaxBatch: int32(r.MaxBatch),
			Enabled: r.Enabled, Position: int32(i),
		})
		if isForeignKeyViolation(err) {
			return llmproxy.ErrUnknownProvider
		}
		if err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// DeleteModel 删除一个对外模型，路由随外键级联删除。
func (s *Store) DeleteModel(ctx context.Context, name string) error {
	n, err := s.q.DeleteLLMModel(ctx, name)
	if err != nil {
		return err
	}
	if n == 0 {
		return llmproxy.ErrNotFound
	}
	return nil
}

func isForeignKeyViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23503"
}
