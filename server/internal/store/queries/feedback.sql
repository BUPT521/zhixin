-- 应用内反馈（internal/store/schema.sql 的 feedback）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次，改一处绑定
-- 不会让另一个位置的 $n 顺序悄悄错位。

-- name: InsertFeedback :exec
INSERT INTO feedback (
  id, content, contact, app_version, platform, diagnostics, created_at
)
VALUES (
  sqlc.arg(id), sqlc.arg(content), sqlc.arg(contact), sqlc.arg(app_version),
  sqlc.arg(platform), sqlc.arg(diagnostics), sqlc.arg(created_at)
);
