-- 账号、登录方式与会话（internal/store/schema.sql 的 app_user、user_identity、
-- auth_code 与 session）。账号只放密码，邮箱这类登录方式各占 user_identity 一行
-- （ADR-0038）。
--
-- 参数一律用 sqlc.arg(名字)：生成的方法按名字取参数，改一处绑定不会让另一个
-- 位置的 $n 顺序悄悄错位。

-- 两个写入都不带 created_at：由表上的默认值给当前时间，账号与登录方式在同一个
-- 事务里写入，时间保持一致。
-- name: CreateUser :exec
INSERT INTO app_user (id, password_hash)
VALUES (sqlc.arg(id), sqlc.arg(password_hash));

-- name: CreateIdentity :exec
INSERT INTO user_identity (id, user_id, kind, identifier)
VALUES (
  sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(kind), sqlc.arg(identifier)
);

-- name: UserByID :one
SELECT id, password_hash, created_at
FROM app_user
WHERE id = sqlc.arg(id);

-- 登录与找回密码都按登录方式定位账号：一种联系方式只用一行，(kind, identifier)
-- 上有唯一约束，所以最多命中一个账号。
-- name: UserByIdentifier :one
SELECT u.id, u.password_hash, u.created_at
FROM app_user AS u
JOIN user_identity AS i ON i.user_id = u.id
WHERE i.kind = sqlc.arg(kind) AND i.identifier = sqlc.arg(identifier);

-- name: IdentitiesByUser :many
SELECT id, user_id, kind, identifier, verified_at, created_at
FROM user_identity
WHERE user_id = sqlc.arg(user_id)
ORDER BY created_at, id;

-- 验证接口只认当前账号名下的登录方式：带着别人的编号来请求得到 0 行，调用方
-- 据此回 404，不区分“不存在”与“不属于这个账号”。
-- name: IdentityByID :one
SELECT id, user_id, kind, identifier, verified_at, created_at
FROM user_identity
WHERE id = sqlc.arg(id) AND user_id = sqlc.arg(user_id);

-- 按登录方式定位账号：登录与找回密码都从这里出发，(kind, identifier) 上有唯一
-- 约束，所以最多命中一条。
-- name: IdentityByIdentifier :one
SELECT id, user_id, kind, identifier, verified_at, created_at
FROM user_identity
WHERE kind = sqlc.arg(kind) AND identifier = sqlc.arg(identifier);

-- name: SetIdentityVerified :exec
UPDATE user_identity
SET verified_at = coalesce(verified_at, sqlc.arg(verified_at)::timestamptz)
WHERE id = sqlc.arg(id) AND user_id = sqlc.arg(user_id);

-- name: UpdatePassword :exec
UPDATE app_user
SET password_hash = sqlc.arg(password_hash)
WHERE id = sqlc.arg(id);

-- name: DeleteUser :execrows
DELETE FROM app_user
WHERE id = sqlc.arg(id);

-- name: CreateSession :exec
INSERT INTO session (
  id, user_id, device_name, access_hash, refresh_hash,
  access_expires, refresh_expires
)
VALUES (
  sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(device_name),
  sqlc.arg(access_hash), sqlc.arg(refresh_hash),
  sqlc.arg(access_expires), sqlc.arg(refresh_expires)
);

-- 建会话之前锁住账号行：同一账号的并发登录在锁上串行，先删最旧再插入，会话
-- 数不会因为并发而超上限。锁的是一行账号，不同账号互不影响。
-- name: LockUser :one
SELECT id FROM app_user WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: LockUserPassword :one
SELECT password_hash FROM app_user WHERE id = sqlc.arg(id) FOR UPDATE;

-- 只保留最新的 keep 条会话，更旧的删掉。排序带上 id，创建时间相同时结果稳定。
-- name: DeleteOldestSessions :exec
DELETE FROM session AS doomed
WHERE doomed.user_id = sqlc.arg(user_id)
  AND doomed.id NOT IN (
    SELECT kept.id
    FROM session AS kept
    WHERE kept.user_id = sqlc.arg(user_id)
    ORDER BY kept.created_at DESC, kept.id DESC
    LIMIT sqlc.arg(keep)
  );

-- name: PruneExpiredSessions :exec
DELETE FROM session
WHERE refresh_expires < sqlc.arg(now);

-- name: PruneExpiredAuthCodes :exec
DELETE FROM auth_code
WHERE expires_at < sqlc.arg(now);

-- name: PruneUsedRefreshTokens :exec
DELETE FROM session_refresh_used WHERE rotated_at < sqlc.arg(used_before);

-- 删除长时间没有任何一种已验证登录方式的账号：注册接口是公开的，没有验证过的
-- 账号不占云盘也不发信，但会一直占着邮箱与账号行（ADR-0037）。只删创建时间早于
-- cutoff 且名下的登录方式都没有确认过的行，会话、验证码、额度与用量随外键级联。
-- name: DeleteUnverifiedUsersBefore :execrows
DELETE FROM app_user AS doomed
WHERE doomed.created_at < sqlc.arg(cutoff)
  AND NOT EXISTS (
    SELECT 1
    FROM user_identity AS identity
    WHERE identity.user_id = doomed.id AND identity.verified_at IS NOT NULL
  );

-- “已验证”指至少有一种登录方式确认过：托管额度与云端写入按它判断，账号页的
-- 提示也读同一处（ADR-0038）。
-- name: SessionByAccessHash :one
SELECT s.id, s.user_id, s.device_name, s.access_hash, s.refresh_hash,
  s.access_expires, s.refresh_expires, s.created_at,
  EXISTS (
    SELECT 1
    FROM user_identity AS identity
    WHERE identity.user_id = s.user_id AND identity.verified_at IS NOT NULL
  )::boolean AS contact_verified
FROM session s
WHERE s.access_hash = sqlc.arg(access_hash);

-- name: SessionByRefreshHash :one
SELECT id, user_id, device_name, access_hash, refresh_hash,
  access_expires, refresh_expires, created_at
FROM session
WHERE refresh_hash = sqlc.arg(refresh_hash);

-- 刷新令牌轮换用 CAS：只有当前的 refresh_hash 还等于旧摘要时才换成新的一对。
-- 并发刷新因此只有一个成功，其余 0 行，调用方据此回 ErrInvalidToken。
-- name: RotateSession :execrows
UPDATE session
SET access_hash = sqlc.arg(new_access_hash),
    refresh_hash = sqlc.arg(new_refresh_hash),
    access_expires = sqlc.arg(access_expires),
    refresh_expires = sqlc.arg(refresh_expires)
WHERE id = sqlc.arg(id) AND refresh_hash = sqlc.arg(old_refresh_hash);

-- 轮换成功时记下旧令牌摘要，供旧令牌再次出现时判断是重试还是盗用。同一个
-- 摘要重复写入（并发或连续重试）时只更新“本次发出的令牌”，宽限截止时间与
-- request_id 保持第一次的值：重试因此不延长宽限期。
-- name: InsertRefreshUsed :exec
INSERT INTO session_refresh_used (
  token_hash, session_id, user_id, request_id, rotated_at, grace_until,
  replaced_access_hash, replaced_refresh_hash
)
VALUES (
  sqlc.arg(token_hash), sqlc.arg(session_id), sqlc.arg(user_id),
  sqlc.arg(request_id), sqlc.arg(rotated_at), sqlc.arg(grace_until),
  sqlc.arg(replaced_access_hash), sqlc.arg(replaced_refresh_hash)
)
ON CONFLICT (token_hash) DO UPDATE SET
  rotated_at = excluded.rotated_at,
  replaced_access_hash = excluded.replaced_access_hash,
  replaced_refresh_hash = excluded.replaced_refresh_hash;

-- name: RefreshUsed :one
SELECT token_hash, session_id, user_id, request_id, rotated_at, grace_until,
  replaced_access_hash, replaced_refresh_hash
FROM session_refresh_used
WHERE token_hash = sqlc.arg(token_hash);

-- name: DeleteSession :execrows
DELETE FROM session
WHERE id = sqlc.arg(id);

-- 重设密码之后作废这个账号的全部会话：其他设备必须重新登录。
-- name: DeleteUserSessions :exec
DELETE FROM session
WHERE user_id = sqlc.arg(user_id);

-- 删账号不单独删会话：schema.sql 的 session.user_id 上是 ON DELETE CASCADE，
-- 删掉 app_user 那一行时一起消失。

-- 验证码按登录方式保存：user_id 允许为空，以后给还没有注册的邮箱或手机号发码
-- 时不用改表。重新发送覆盖同一 (purpose, kind, identifier) 的那一枚。
-- name: PutAuthCode :exec
INSERT INTO auth_code (
  purpose, kind, identifier, user_id, code_hash, expires_at, attempts, created_at
)
VALUES (
  sqlc.arg(purpose), sqlc.arg(kind), sqlc.arg(identifier), sqlc.narg(user_id),
  sqlc.arg(code_hash), sqlc.arg(expires_at), 0, sqlc.arg(created_at)
)
ON CONFLICT (purpose, kind, identifier) DO UPDATE SET
  user_id = excluded.user_id,
  code_hash = excluded.code_hash,
  expires_at = excluded.expires_at,
  attempts = 0,
  created_at = excluded.created_at;

-- name: AuthCode :one
SELECT purpose, kind, identifier, user_id, code_hash, expires_at, attempts, created_at
FROM auth_code
WHERE purpose = sqlc.arg(purpose)
  AND kind = sqlc.arg(kind)
  AND identifier = sqlc.arg(identifier);

-- name: IncrementAuthCodeAttempts :one
UPDATE auth_code
SET attempts = attempts + 1
WHERE purpose = sqlc.arg(purpose)
  AND kind = sqlc.arg(kind)
  AND identifier = sqlc.arg(identifier)
RETURNING attempts;

-- name: DeleteAuthCode :exec
DELETE FROM auth_code
WHERE purpose = sqlc.arg(purpose)
  AND kind = sqlc.arg(kind)
  AND identifier = sqlc.arg(identifier);

-- 重设密码时用掉验证码：只有摘要匹配且未过期才删，0 行说明验证码已经被别的
-- 请求用掉、已过期或对不上，调用方据此回 ErrInvalidCode。
-- name: DeleteAuthCodeIfMatch :execrows
DELETE FROM auth_code
WHERE purpose = sqlc.arg(purpose)
  AND kind = sqlc.arg(kind)
  AND identifier = sqlc.arg(identifier)
  AND code_hash = sqlc.arg(code_hash)
  AND expires_at > sqlc.arg(now);

-- 模型代理的接入密钥（schema.sql 的 api_key，ADR-0063）。密钥本身只在签发那一
-- 次出现在响应里，库里只有 SHA-256；查询按摘要定位，前缀只用于展示。

-- name: CreateApiKey :exec
INSERT INTO api_key (id, user_id, name, prefix, key_hash)
VALUES (
  sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(name), sqlc.arg(prefix),
  sqlc.arg(key_hash)
);

-- name: ApiKeysByUser :many
SELECT id, user_id, name, prefix, revoked_at, last_used_at, created_at
FROM api_key
WHERE user_id = sqlc.arg(user_id)
ORDER BY created_at DESC, id DESC;

-- 鉴权只认没有撤销的密钥；“已验证”与访问令牌同一口径，至少一种登录方式确认过。
-- name: ApiKeyByHash :one
SELECT k.id, k.user_id, k.name, k.prefix, k.revoked_at, k.last_used_at,
  k.created_at,
  EXISTS (
    SELECT 1
    FROM user_identity AS identity
    WHERE identity.user_id = k.user_id AND identity.verified_at IS NOT NULL
  )::boolean AS contact_verified
FROM api_key AS k
WHERE k.key_hash = sqlc.arg(key_hash) AND k.revoked_at IS NULL;

-- 撤销只对当前账号名下、还没有撤销过的密钥生效；0 行按找不到处理。
-- name: RevokeApiKey :execrows
UPDATE api_key
SET revoked_at = now()
WHERE id = sqlc.arg(id) AND user_id = sqlc.arg(user_id) AND revoked_at IS NULL;

-- 最近使用时间只用于辨认，十分钟粒度足够，避免每次模型请求都写一行。
-- name: TouchApiKey :exec
UPDATE api_key
SET last_used_at = now()
WHERE id = sqlc.arg(id)
  AND (last_used_at IS NULL OR last_used_at < now() - interval '10 minutes');

-- 撤销账号的全部密钥：手动“撤销全部”与重设密码都用它，已经撤销的行保持不变。
-- name: RevokeApiKeysByUser :execrows
UPDATE api_key
SET revoked_at = now()
WHERE user_id = sqlc.arg(user_id) AND revoked_at IS NULL;
