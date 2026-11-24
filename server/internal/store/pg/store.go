// Package pg 是 auth、syncsvc、backup 与 llmproxy 四个存储接口的 PostgreSQL 实现。
//
// 查询写进 internal/store/queries 下的 .sql 文件，由 sqlc 生成带类型的方法
// （ADR-0015 第一项）。表结构唯一真相是 internal/store/schema.sql；开发阶段不写
// 迁移，结构变化时按它重建（ADR-0001）。
package pg

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/store"
	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// Store 同时实现四个存储接口；账号删除靠外键级联清理其余表，所以
// DeleteUser 只有一份，语义是“删除这个账号”。
type Store struct {
	pool    *pgxpool.Pool
	q       *db.Queries
	objects objectstore.Store

	// dailyTokens 与 instanceDailyTokens 是配置里的默认每日额度与实例预算，由
	// llmproxy.NewHandler 装配时经 SetQuotaLimits 注入（见 quota.go），运行期间
	// 不再修改，因此不加锁。
	dailyTokens           int64
	embeddingDailyTokens  int64
	instanceDailyTokens   int64
	purchasedQuotaEnabled bool
	purchasedQuotaSandbox bool
}

var (
	_ auth.Store           = (*Store)(nil)
	_ syncsvc.Store        = (*Store)(nil)
	_ backup.Store         = (*Store)(nil)
	_ llmproxy.Quota       = (*Store)(nil)
	_ feedback.Store       = (*Store)(nil)
	_ retention.Store      = (*Store)(nil)
	_ blobs.Store          = (*BlobStore)(nil)
	_ interface{ Close() } = (*Store)(nil)
)

// Options 是打开连接时的可选项。
type Options struct {
	// Objects 存放整库备份的字节；S3、本地目录与内存三种实现在 objectstore 里。
	Objects objectstore.Store
	// MaxConns 为空时用 pgxpool 的默认值。
	MaxConns int32
	// PurchasedQuotaEnabled requires the payment tables in schema.sql.
	PurchasedQuotaEnabled bool
	PurchasedQuotaSandbox bool
}

// Open 连接 PostgreSQL 并返回四个接口共用的实现。
func Open(ctx context.Context, dsn string, opts Options) (*Store, error) {
	if opts.Objects == nil {
		return nil, errors.New("pg: 需要 objectstore.Store 存放备份字节")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("pg: 解析连接串失败: %w", err)
	}
	if opts.MaxConns > 0 {
		cfg.MaxConns = opts.MaxConns
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pg: 建立连接池失败: %w", err)
	}
	return &Store{pool: pool, q: db.New(pool), objects: opts.Objects, purchasedQuotaEnabled: opts.PurchasedQuotaEnabled, purchasedQuotaSandbox: opts.PurchasedQuotaSandbox}, nil
}

// Ping 报告数据库是否可达，供 /readyz 使用。
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// Close 关闭连接池。
func (s *Store) Close() { s.pool.Close() }

// ApplySchema 在空库上按 schema.sql 建表；库已有表时保持原样。
func (s *Store) ApplySchema(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, store.Schema)
	if err != nil {
		return fmt.Errorf("pg: 建表失败: %w", err)
	}
	return nil
}

// ---- auth.Store ----

// CreateAccount 在一个事务里写入账号与它的第一种登录方式：登录方式撞上
// (kind, identifier) 的唯一约束时整个账号都不落地，返回 ErrIdentifierTaken。
// 两个创建时间都由表上的默认值给出。
func (s *Store) CreateAccount(ctx context.Context, u auth.User, ident auth.Identity) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)
	if err := q.CreateUser(ctx, db.CreateUserParams{
		ID:           u.ID,
		PasswordHash: u.PasswordHash,
	}); err != nil {
		return err
	}
	if err := q.CreateIdentity(ctx, db.CreateIdentityParams{
		ID:         ident.ID,
		UserID:     ident.UserID,
		Kind:       ident.Kind,
		Identifier: ident.Identifier,
	}); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return auth.ErrIdentifierTaken
		}
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) UserByID(ctx context.Context, id string) (auth.User, error) {
	row, err := s.q.UserByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.User{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.User{}, err
	}
	return auth.User{
		ID:           row.ID,
		PasswordHash: row.PasswordHash,
		CreatedAt:    row.CreatedAt.Time,
	}, nil
}

func (s *Store) UserByIdentifier(ctx context.Context, kind, identifier string) (auth.User, error) {
	row, err := s.q.UserByIdentifier(ctx, db.UserByIdentifierParams{Kind: kind, Identifier: identifier})
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.User{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.User{}, err
	}
	return auth.User{
		ID:           row.ID,
		PasswordHash: row.PasswordHash,
		CreatedAt:    row.CreatedAt.Time,
	}, nil
}

func (s *Store) Identities(ctx context.Context, userID string) ([]auth.Identity, error) {
	rows, err := s.q.IdentitiesByUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	identities := make([]auth.Identity, 0, len(rows))
	for _, row := range rows {
		identities = append(identities, identityFromRow(row))
	}
	return identities, nil
}

func (s *Store) Identity(ctx context.Context, userID, identityID string) (auth.Identity, error) {
	row, err := s.q.IdentityByID(ctx, db.IdentityByIDParams{ID: identityID, UserID: userID})
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Identity{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Identity{}, err
	}
	return identityFromRow(row), nil
}

func (s *Store) IdentityByIdentifier(ctx context.Context, kind, identifier string) (auth.Identity, error) {
	row, err := s.q.IdentityByIdentifier(ctx, db.IdentityByIdentifierParams{Kind: kind, Identifier: identifier})
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Identity{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Identity{}, err
	}
	return identityFromRow(row), nil
}

func (s *Store) SetIdentityVerified(ctx context.Context, userID, identityID string, at time.Time) error {
	verified, err := pgTime(at)
	if err != nil {
		return err
	}
	return s.q.SetIdentityVerified(ctx, db.SetIdentityVerifiedParams{
		VerifiedAt: verified,
		ID:         identityID,
		UserID:     userID,
	})
}

// identityFromRow 把库里的一行登录方式转成 auth 的类型；verified_at 为空时
// VerifiedAt 保持零值，含义是“还没有确认”。
func identityFromRow(row db.UserIdentity) auth.Identity {
	return auth.Identity{
		ID:         row.ID,
		UserID:     row.UserID,
		Kind:       row.Kind,
		Identifier: row.Identifier,
		VerifiedAt: row.VerifiedAt.Time,
		CreatedAt:  row.CreatedAt.Time,
	}
}

// DeleteUser 删除账号行；会话、提交序列、备份元数据与用量按外键级联删除。
// 对象存储里的字节由 DeleteUserObjects 清理，两步分开，账号删除因此可以重试。
func (s *Store) DeleteUser(ctx context.Context, userID string) error {
	_, err := s.q.DeleteUser(ctx, userID)
	return err
}

// DeleteUserObjects 删除账号名下的备份字节。附件字节由 blobs 包按自己的前缀
// 清理，两个前缀不同，服务装配时合成一次账号清理。
func (s *Store) DeleteUserObjects(ctx context.Context, userID string) error {
	return s.objects.RemovePrefix(ctx, objectstore.BackupPrefix(userID))
}

// CreateSession 在一个事务里先锁住账号行、删掉超出上限的旧会话，再插入新会话。
// 锁让同一账号的并发登录串行执行，会话数不会被并发推过上限；等待锁的时间很短，
// 因为整个事务只碰会话表与锁住的那一行账号。
func (s *Store) CreateSession(ctx context.Context, sess auth.Session, maxPerUser int, checkedHash string) error {
	if maxPerUser < 1 {
		maxPerUser = 1
	}
	accessExpires, err := pgTime(sess.AccessExpires)
	if err != nil {
		return err
	}
	refreshExpires, err := pgTime(sess.RefreshExpires)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	currentHash, err := q.LockUserPassword(ctx, sess.UserID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// 账号在登录过程中被删掉了；新会话没有可依附的账号行。
			return auth.ErrNotFound
		}
		return err
	}
	if checkedHash != "" && currentHash != checkedHash {
		return auth.ErrInvalidCredentials
	}
	if err := q.DeleteOldestSessions(ctx, db.DeleteOldestSessionsParams{
		UserID: sess.UserID,
		Keep:   int32(maxPerUser - 1),
	}); err != nil {
		return err
	}
	if err := q.CreateSession(ctx, db.CreateSessionParams{
		ID:             sess.ID,
		UserID:         sess.UserID,
		DeviceName:     sess.DeviceName,
		AccessHash:     sess.AccessHash,
		RefreshHash:    sess.RefreshHash,
		AccessExpires:  accessExpires,
		RefreshExpires: refreshExpires,
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) SessionByAccessHash(ctx context.Context, hash string) (auth.Session, error) {
	row, err := s.q.SessionByAccessHash(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Session{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Session{}, err
	}
	return auth.Session{
		ID:              row.ID,
		UserID:          row.UserID,
		DeviceName:      row.DeviceName,
		AccessHash:      row.AccessHash,
		RefreshHash:     row.RefreshHash,
		AccessExpires:   row.AccessExpires.Time,
		RefreshExpires:  row.RefreshExpires.Time,
		CreatedAt:       row.CreatedAt.Time,
		ContactVerified: row.ContactVerified,
	}, nil
}

func (s *Store) SessionByRefreshHash(ctx context.Context, hash string) (auth.Session, error) {
	row, err := s.q.SessionByRefreshHash(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Session{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Session{}, err
	}
	return auth.Session{
		ID:             row.ID,
		UserID:         row.UserID,
		DeviceName:     row.DeviceName,
		AccessHash:     row.AccessHash,
		RefreshHash:    row.RefreshHash,
		AccessExpires:  row.AccessExpires.Time,
		RefreshExpires: row.RefreshExpires.Time,
		CreatedAt:      row.CreatedAt.Time,
	}, nil
}

func (s *Store) DeleteSession(ctx context.Context, id string) error {
	deleted, err := s.q.DeleteSession(ctx, id)
	if err == nil && deleted == 0 {
		return auth.ErrNotFound
	}
	return err
}

// RotateSession 用 CAS 换掉令牌摘要。0 行说明这条会话的刷新令牌已经被换过，
// 返回 ErrInvalidToken，让并发的第二个刷新请求失败。
func (s *Store) RotateSession(ctx context.Context, id, oldRefreshHash, newAccessHash, newRefreshHash string, accessExpires, refreshExpires time.Time) error {
	access, err := pgTime(accessExpires)
	if err != nil {
		return err
	}
	refresh, err := pgTime(refreshExpires)
	if err != nil {
		return err
	}
	updated, err := s.q.RotateSession(ctx, db.RotateSessionParams{
		NewAccessHash:  newAccessHash,
		NewRefreshHash: newRefreshHash,
		AccessExpires:  access,
		RefreshExpires: refresh,
		ID:             id,
		OldRefreshHash: oldRefreshHash,
	})
	if err != nil {
		return err
	}
	if updated == 0 {
		return auth.ErrInvalidToken
	}
	return nil
}

// RotateSessionAndRecord 在一个事务里先做 CAS 轮换、再写重放记录：0 行说明轮换
// 输给了并发的另一个请求，整个事务回滚；记录写入失败同样回滚轮换。客户端因此
// 要么拿到新令牌且旧摘要已经记下，要么旧令牌仍然可用，不存在只换令牌、旧摘要
// 没记下的中间状态。
func (s *Store) RotateSessionAndRecord(ctx context.Context, id, oldRefreshHash, newAccessHash, newRefreshHash string, accessExpires, refreshExpires time.Time, used auth.RefreshUsed) error {
	access, err := pgTime(accessExpires)
	if err != nil {
		return err
	}
	refresh, err := pgTime(refreshExpires)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	updated, err := q.RotateSession(ctx, db.RotateSessionParams{
		NewAccessHash:  newAccessHash,
		NewRefreshHash: newRefreshHash,
		AccessExpires:  access,
		RefreshExpires: refresh,
		ID:             id,
		OldRefreshHash: oldRefreshHash,
	})
	if err != nil {
		return err
	}
	if updated == 0 {
		return auth.ErrInvalidToken
	}
	// 记录里的“本次发出的令牌”按刚写入会话的摘要填好，调用方不用设置，两条
	// 记录因此不会与轮换后的会话写成不同的令牌。
	used.ReplacedAccessHash = newAccessHash
	used.ReplacedRefreshHash = newRefreshHash
	if err := insertRefreshUsed(ctx, q, used); err != nil {
		return err
	}
	if used.TokenHash != oldRefreshHash {
		// 宽限期内的重试：客户端提交的更早摘要与这次消费的当前摘要不是同一个，
		// 两条记录都要指向本次发出的新令牌，连续重试才都按重试处理。
		other := used
		other.TokenHash = oldRefreshHash
		if err := insertRefreshUsed(ctx, q, other); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// insertRefreshUsed 把一条重放记录写进给定的查询句柄，事务里与事务外共用。
func insertRefreshUsed(ctx context.Context, q *db.Queries, u auth.RefreshUsed) error {
	rotated, err := pgTime(u.RotatedAt)
	if err != nil {
		return err
	}
	grace, err := pgTime(u.GraceUntil)
	if err != nil {
		return err
	}
	return q.InsertRefreshUsed(ctx, db.InsertRefreshUsedParams{
		TokenHash:           u.TokenHash,
		SessionID:           u.SessionID,
		UserID:              u.UserID,
		RequestID:           u.RequestID,
		RotatedAt:           rotated,
		GraceUntil:          grace,
		ReplacedAccessHash:  u.ReplacedAccessHash,
		ReplacedRefreshHash: u.ReplacedRefreshHash,
	})
}

func (s *Store) UsedRefresh(ctx context.Context, tokenHash string) (auth.RefreshUsed, error) {
	row, err := s.q.RefreshUsed(ctx, tokenHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.RefreshUsed{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.RefreshUsed{}, err
	}
	return auth.RefreshUsed{
		TokenHash:           row.TokenHash,
		SessionID:           row.SessionID,
		UserID:              row.UserID,
		RequestID:           row.RequestID,
		RotatedAt:           row.RotatedAt.Time,
		GraceUntil:          row.GraceUntil.Time,
		ReplacedAccessHash:  row.ReplacedAccessHash,
		ReplacedRefreshHash: row.ReplacedRefreshHash,
	}, nil
}

func (s *Store) RecordRefreshUsed(ctx context.Context, u auth.RefreshUsed) error {
	return insertRefreshUsed(ctx, s.q, u)
}

func (s *Store) DeleteUserSessions(ctx context.Context, userID string) error {
	return s.q.DeleteUserSessions(ctx, userID)
}

// PruneExpired 删除刷新令牌已过期的会话与已过期的验证码，两张表的清理互相
// 独立，一条失败时另一条照常执行会让接口语义含糊，所以按顺序执行并在第一条
// 出错时返回；每日清理下一次还会再试。
func (s *Store) PruneExpired(ctx context.Context, now, usedBefore time.Time) error {
	at, err := pgTime(now)
	if err != nil {
		return err
	}
	if err := s.q.PruneExpiredSessions(ctx, at); err != nil {
		return err
	}
	if err := s.q.PruneExpiredAuthCodes(ctx, at); err != nil {
		return err
	}
	cutoff, err := pgTime(usedBefore)
	if err != nil {
		return err
	}
	return s.q.PruneUsedRefreshTokens(ctx, cutoff)
}

// PruneUnverified 删除创建时间早于 before、且没有任何一种已验证登录方式的账号，
// 返回删除的账号数。登录方式、会话、验证码、重放记录与其余账号数据按 schema 的
// 外键级联删除；这是每日清理的一部分，注册是公开入口，超过保留期仍未确认的账号
// 行会一直占着联系方式。
func (s *Store) PruneUnverified(ctx context.Context, before time.Time) (int64, error) {
	cutoff, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	return s.q.DeleteUnverifiedUsersBefore(ctx, cutoff)
}

func (s *Store) UpdatePassword(ctx context.Context, userID, passwordHash string) error {
	return s.q.UpdatePassword(ctx, db.UpdatePasswordParams{ID: userID, PasswordHash: passwordHash})
}

// ResetPassword 在一个事务里用掉验证码、换密码、确认那种登录方式、删会话。验证码
// 的删除带用途、登录方式、摘要与有效期条件，0 行说明它已经被别的请求用掉或过期，
// 此时整个事务回滚，密码、登录方式与会话都不动。
func (s *Store) ResetPassword(ctx context.Context, reset auth.PasswordReset) error {
	at, err := pgTime(reset.Now)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	used, err := q.DeleteAuthCodeIfMatch(ctx, db.DeleteAuthCodeIfMatchParams{
		Purpose:    reset.Purpose,
		Kind:       reset.Kind,
		Identifier: reset.Identifier,
		CodeHash:   reset.ExpectedHash,
		Now:        at,
	})
	if err != nil {
		return err
	}
	if used == 0 {
		return auth.ErrInvalidCode
	}
	if err := q.UpdatePassword(ctx, db.UpdatePasswordParams{
		ID:           reset.UserID,
		PasswordHash: reset.NewPasswordHash,
	}); err != nil {
		return err
	}
	if err := q.SetIdentityVerified(ctx, db.SetIdentityVerifiedParams{
		VerifiedAt: at,
		ID:         reset.IdentityID,
		UserID:     reset.UserID,
	}); err != nil {
		return err
	}
	if err := q.DeleteUserSessions(ctx, reset.UserID); err != nil {
		return err
	}
	// 重设密码通常意味着账号可能已经泄露，模型代理密钥在同一次事务里全部撤销
	// （ADR-0063）。
	if _, err := q.RevokeApiKeysByUser(ctx, reset.UserID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) PutCode(ctx context.Context, c auth.Code) error {
	expires, err := pgTime(c.ExpiresAt)
	if err != nil {
		return err
	}
	created, err := pgTime(c.CreatedAt)
	if err != nil {
		return err
	}
	return s.q.PutAuthCode(ctx, db.PutAuthCodeParams{
		Purpose:    c.Purpose,
		Kind:       c.Kind,
		Identifier: c.Identifier,
		UserID:     nullableText(c.UserID),
		CodeHash:   c.CodeHash,
		ExpiresAt:  expires,
		CreatedAt:  created,
	})
}

func (s *Store) Code(ctx context.Context, purpose, kind, identifier string) (auth.Code, error) {
	row, err := s.q.AuthCode(ctx, db.AuthCodeParams{
		Purpose:    purpose,
		Kind:       kind,
		Identifier: identifier,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Code{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Code{}, err
	}
	return auth.Code{
		Purpose:    row.Purpose,
		Kind:       row.Kind,
		Identifier: row.Identifier,
		UserID:     row.UserID.String,
		CodeHash:   row.CodeHash,
		ExpiresAt:  row.ExpiresAt.Time,
		Attempts:   int(row.Attempts),
		CreatedAt:  row.CreatedAt.Time,
	}, nil
}

func (s *Store) IncrementCodeAttempts(ctx context.Context, purpose, kind, identifier string) (int, error) {
	attempts, err := s.q.IncrementAuthCodeAttempts(ctx, db.IncrementAuthCodeAttemptsParams{
		Purpose:    purpose,
		Kind:       kind,
		Identifier: identifier,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, auth.ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	return int(attempts), nil
}

func (s *Store) DeleteCode(ctx context.Context, purpose, kind, identifier string) error {
	return s.q.DeleteAuthCode(ctx, db.DeleteAuthCodeParams{
		Purpose:    purpose,
		Kind:       kind,
		Identifier: identifier,
	})
}

// nullableText 把空串写成 NULL：验证码的 user_id 允许为空，含义是这条联系方式
// 还没有账号，与“空字符串账号编号”区分开。
func nullableText(value string) pgtype.Text {
	if value == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: value, Valid: true}
}

// CreateFeedback 保存一条应用内反馈。反馈不关联账号，删号时也没有需要级联的
// 行；管理员按 created_at 直接查表，见 server/README。
func (s *Store) CreateFeedback(ctx context.Context, item feedback.Item) error {
	created, err := pgTime(item.CreatedAt)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('feedback_capacity'))`); err != nil {
		return err
	}
	q := s.q.WithTx(tx)
	count, err := q.FeedbackCount(ctx)
	if err != nil {
		return err
	}
	if count >= feedback.MaxRetainedItems {
		return feedback.ErrCapacity
	}
	if err := q.InsertFeedback(ctx, db.InsertFeedbackParams{
		ID:          item.ID,
		Content:     item.Content,
		Contact:     item.Contact,
		AppVersion:  item.AppVersion,
		Platform:    item.Platform,
		Diagnostics: item.Diagnostics,
		CreatedAt:   created,
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// DeleteBefore 删除创建时间早于 before 的反馈，返回删除的行数。保留期起点由
// internal/feedback 按保留天数算出，这里只按时间条件删除。
func (s *Store) DeleteBefore(ctx context.Context, before time.Time) (int64, error) {
	ts, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	return s.q.DeleteFeedbackBefore(ctx, ts)
}

// pgTime 把时间转成 PostgreSQL 的 timestamptz。零值说明调用方漏了赋值，直接
// 报错，不再静默写成 NULL 或 0001-01-01 这类看不见的错误数据。
func pgTime(t time.Time) (pgtype.Timestamptz, error) {
	if t.IsZero() {
		return pgtype.Timestamptz{}, errors.New("pg: 时间字段为零值")
	}
	return pgtype.Timestamptz{Time: t, Valid: true}, nil
}
