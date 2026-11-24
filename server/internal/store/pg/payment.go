package pg

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/payment"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

var _ payment.Store = (*Store)(nil)

func purchase(row db.ModelQuotaPurchase, err error) (payment.Order, error) {
	if errors.Is(err, pgx.ErrNoRows) {
		return payment.Order{}, payment.ErrOrderNotFound
	}
	if err != nil {
		return payment.Order{}, err
	}
	return payment.Order{
		ID: row.ID, UserID: row.UserID.String, AppID: row.AppID, SellerID: row.SellerID,
		Offer:   payment.Offer{AmountFen: row.AmountFen, Tokens: row.Tokens},
		Sandbox: row.Sandbox, Status: row.Status, CreatedAt: row.CreatedAt.Time, ExpiresAt: row.ExpiresAt.Time,
	}, nil
}

func (s *Store) CheckPurchaseSchema(ctx context.Context) error {
	var installed bool
	err := s.pool.QueryRow(ctx, `SELECT to_regclass('model_quota_purchase') IS NOT NULL
		AND to_regclass('model_quota_wallet') IS NOT NULL
		AND to_regclass('model_quota_paid_usage') IS NOT NULL`).Scan(&installed)
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("pg: 支付宝收款需要按 schema.sql 建好模型额度购买表")
	}
	return nil
}

func (s *Store) PurchaseBalance(ctx context.Context, userID string) (int64, error) {
	balance, err := s.q.PurchaseBalance(ctx, db.PurchaseBalanceParams{UserID: userID, Sandbox: s.purchasedQuotaSandbox})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return balance, err
}

func (s *Store) LatestPurchase(ctx context.Context, userID string) (payment.Order, error) {
	return purchase(s.q.LatestPurchase(ctx, db.LatestPurchaseParams{
		UserID: pgtype.Text{String: userID, Valid: true}, Sandbox: s.purchasedQuotaSandbox,
	}))
}

func (s *Store) FindPurchase(ctx context.Context, id string) (payment.Order, error) {
	return purchase(s.q.FindPurchase(ctx, id))
}

func (s *Store) CreatePurchase(ctx context.Context, order payment.Order) (payment.Order, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return payment.Order{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := db.New(tx)
	if _, err := q.LockPurchaseOwner(ctx, order.UserID); err != nil {
		return payment.Order{}, err
	}
	user := pgtype.Text{String: order.UserID, Valid: true}
	latest, err := purchase(q.LatestPurchase(ctx, db.LatestPurchaseParams{UserID: user, Sandbox: order.Sandbox}))
	if err != nil && !errors.Is(err, payment.ErrOrderNotFound) {
		return payment.Order{}, err
	}
	if latest.Status == payment.Pending && latest.ExpiresAt.After(order.CreatedAt) {
		return latest, nil
	}
	created, err := purchase(q.InsertPurchase(ctx, db.InsertPurchaseParams{
		ID: order.ID, UserID: user, AmountFen: order.AmountFen, Tokens: order.Tokens,
		AppID: order.AppID, SellerID: order.SellerID, Sandbox: order.Sandbox,
		CreatedAt: pgtype.Timestamptz{Time: order.CreatedAt, Valid: true},
		ExpiresAt: pgtype.Timestamptz{Time: order.ExpiresAt, Valid: true},
	}))
	if err != nil {
		return payment.Order{}, err
	}
	return created, tx.Commit(ctx)
}

// ApplyPurchase 按先锁账号、后锁订单的顺序串行发放，同一支付宝交易号只能绑定一笔订单。
func (s *Store) ApplyPurchase(ctx context.Context, order payment.Order, tradeID, status string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := db.New(tx)
	if order.UserID != "" {
		if _, err := q.LockPurchaseOwner(ctx, order.UserID); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
	}
	row, err := q.LockPurchase(ctx, order.ID)
	if err != nil {
		return err
	}
	if row.TradeID.Valid && row.TradeID.String != tradeID {
		return payment.ErrInvalidTrade
	}
	if row.Status != payment.Pending {
		return nil
	}
	if err := q.SetPurchaseStatus(ctx, db.SetPurchaseStatusParams{
		ID: row.ID, Status: status, TradeID: pgtype.Text{String: tradeID, Valid: true},
	}); err != nil {
		return err
	}
	if status == payment.Paid && row.UserID.Valid {
		if err := q.CreditPurchaseBalance(ctx, db.CreditPurchaseBalanceParams{
			UserID: row.UserID.String, Sandbox: row.Sandbox, BalanceTokens: row.Tokens,
		}); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

type purchasedQuota struct {
	balance int64
	used    int64
}

func (s *Store) lockPurchasedQuota(ctx context.Context, q *db.Queries, userID string, day pgtype.Date) (purchasedQuota, error) {
	balance, err := q.LockPurchaseBalance(ctx, db.LockPurchaseBalanceParams{UserID: userID, Sandbox: s.purchasedQuotaSandbox})
	if errors.Is(err, pgx.ErrNoRows) {
		return purchasedQuota{}, nil
	}
	if err != nil {
		return purchasedQuota{}, err
	}
	used, err := q.PurchasedTokensUsed(ctx, db.PurchasedTokensUsedParams{UserID: userID, Sandbox: s.purchasedQuotaSandbox, Day: day})
	return purchasedQuota{balance: balance, used: used}, err
}

func (s *Store) adjustPurchasedQuota(ctx context.Context, q *db.Queries, userID string, day pgtype.Date, spent int64) error {
	if spent == 0 {
		return nil
	}
	if err := q.AdjustPurchaseBalance(ctx, db.AdjustPurchaseBalanceParams{UserID: userID, Sandbox: s.purchasedQuotaSandbox, Spent: spent}); err != nil {
		return err
	}
	return q.AddPurchasedTokensUsed(ctx, db.AddPurchasedTokensUsedParams{UserID: userID, Sandbox: s.purchasedQuotaSandbox, Day: day, Spent: spent})
}
