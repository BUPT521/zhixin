-- 知新 API 后端 · PostgreSQL 表结构草案（ADR-0009）
--
-- 开发阶段不写迁移（ADR-0001）：结构变化时直接按本文件重建库。
-- 服务端不解析学习内容：同步变更与备份按客户端提交原样保存。

CREATE TABLE app_user (
  id                 TEXT PRIMARY KEY,
  email              TEXT NOT NULL UNIQUE,      -- 已转小写
  password_hash      TEXT NOT NULL,             -- argon2id，PHC 格式
  email_verified_at  TIMESTAMPTZ,               -- 空表示还没有确认邮箱
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 邮箱验证与找回密码共用的验证码：每个账号每种用途只保留最新一枚，
-- 只存 HMAC-SHA256（验证码只有六位，直接存哈希可以被穷举）。过期或输错次数
-- 达到上限时删除，重新发送时覆盖。
CREATE TABLE auth_code (
  user_id     TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  purpose     TEXT NOT NULL CHECK (purpose IN ('verify_email', 'reset_password')),
  code_hash   TEXT NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, purpose)
);

-- 一台登录的设备一行；只存令牌的 SHA-256。
CREATE TABLE session (
  id               TEXT PRIMARY KEY,
  user_id          TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  device_name      TEXT NOT NULL DEFAULT '',
  access_hash      TEXT NOT NULL UNIQUE,
  refresh_hash     TEXT NOT NULL UNIQUE,
  access_expires   TIMESTAMPTZ NOT NULL,
  refresh_expires  TIMESTAMPTZ NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX session_by_user ON session(user_id);

-- 每个账号一条线性提交序列。推送时在同一事务里 SELECT ... FOR UPDATE
-- 锁住 sync_head，核对 base_seq = head 之后再追加。
CREATE TABLE sync_head (
  user_id  TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  head     BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE sync_commit (
  user_id         TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  seq             BIGINT NOT NULL,
  request_id      TEXT NOT NULL,               -- 客户端 revision_commit.request_id，重试去重
  device_id       TEXT NOT NULL,
  schema_version  INTEGER NOT NULL,
  actor           TEXT NOT NULL CHECK (actor IN ('user', 'ai', 'system')),
  action          TEXT NOT NULL,
  created_at      TEXT NOT NULL,               -- 客户端时间，格式同 docs/01 D7
  received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  changes         JSONB NOT NULL,              -- [{table,row_key,op,before,after}]
  PRIMARY KEY (user_id, seq),
  UNIQUE (user_id, request_id)
);

-- 整库备份：字节在对象存储的 backups/<user_id>/<id>.zip。
CREATE TABLE backup (
  id              TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  sha256          TEXT NOT NULL,
  size            BIGINT NOT NULL,
  schema_version  INTEGER NOT NULL,
  device_name     TEXT NOT NULL DEFAULT '',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX backup_user_created ON backup(user_id, created_at DESC);

-- 模型代理用量：只记 token 数，不记请求与回答正文。
CREATE TABLE llm_usage (
  user_id  TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day      DATE NOT NULL,                      -- ZHIXIN_TIMEZONE 下的自然日
  tokens   BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);

