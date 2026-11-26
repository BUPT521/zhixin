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

-- name: FeedbackCount :one
SELECT count(*) FROM feedback;

-- name: DeleteFeedbackBefore :execrows
-- 保留期清理：删除创建时间早于 before 的反馈，返回删除的行数（internal/feedback
-- 的 PruneLoop 每天调用一次，见 server/README 的应用内反馈）。
DELETE FROM feedback WHERE created_at < sqlc.arg(before);

-- 管理后台的关键字检索：编号、正文、联系邮箱、版本与平台，空值列出全部。与
-- 账号列表一样用 position(lower(...))，管理员输入的 % 与 _ 按普通字符匹配；
-- 反馈表上限一万行，全表扫描的代价可以接受。
-- name: CountFeedback :one
SELECT count(*)::bigint
FROM feedback AS f
WHERE sqlc.arg(query)::text = ''
   OR position(lower(sqlc.arg(query)::text) in lower(f.id)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.content)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.contact)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.app_version)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.platform)) > 0;

-- name: ListFeedback :many
-- 列表只带“有没有诊断摘要”，不把每条至多 64 KiB 的诊断摘要一起读出。
SELECT f.id, f.content, f.contact, f.app_version, f.platform,
       (f.diagnostics <> '') AS has_diagnostics, f.created_at
FROM feedback AS f
WHERE sqlc.arg(query)::text = ''
   OR position(lower(sqlc.arg(query)::text) in lower(f.id)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.content)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.contact)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.app_version)) > 0
   OR position(lower(sqlc.arg(query)::text) in lower(f.platform)) > 0
ORDER BY f.created_at DESC, f.id
LIMIT sqlc.arg(row_limit)::int OFFSET sqlc.arg(row_offset)::int;

-- name: FeedbackByID :one
SELECT id, content, contact, app_version, platform, diagnostics, created_at
FROM feedback
WHERE id = sqlc.arg(id);

-- name: DeleteFeedbackByID :execrows
DELETE FROM feedback WHERE id = sqlc.arg(id);
