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

-- 应用内反馈：登录与否都可以提交，不关联账号，删号也不影响已经提交的反馈。
-- 正文与诊断摘要是用户主动写的，服务端不解析；读取由管理员直接查这张表，
-- 不另开列表接口（ADR-0025）。
CREATE TABLE feedback (
  id           TEXT PRIMARY KEY,
  content      TEXT NOT NULL,
  contact      TEXT NOT NULL DEFAULT '',
  app_version  TEXT NOT NULL DEFAULT '',
  platform     TEXT NOT NULL DEFAULT '',
  diagnostics  TEXT NOT NULL DEFAULT '',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX feedback_created ON feedback(created_at DESC);

-- 登录账号的活跃：一行是一天，按服务端收到的请求日期记（ADR-0019）。
CREATE TABLE user_active (
  user_id  TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day      DATE NOT NULL,                      -- ZHIXIN_TIMEZONE 下的自然日
  PRIMARY KEY (user_id, day)
);
CREATE INDEX user_active_day ON user_active(day);

-- 未登录设备的匿名活跃：只保存安装标识的 HMAC-SHA256 与日期，原始标识不落库；
-- 按 180 天滚动删除（ADR-0019）。
CREATE TABLE install_active (
  install_hash  TEXT NOT NULL,
  day           DATE NOT NULL,
  app_version   TEXT NOT NULL DEFAULT '',
  platform      TEXT NOT NULL DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (install_hash, day)
);
CREATE INDEX install_active_day ON install_active(day);

-- 按账号调整每日模型额度：没有行时用 ZHIXIN_LLM_DAILY_TOKENS。管理员直接写
-- 这张表调整个别账号，不重启服务，也不另开管理接口。
CREATE TABLE llm_quota (
  user_id       TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  daily_tokens  BIGINT NOT NULL CHECK (daily_tokens > 0),
  note          TEXT NOT NULL DEFAULT '',
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 附件索引：字节在对象存储的 attachments/<user_id>/<sha256>，这张表只记“这个
-- 账号有这份内容、占多少字节”。账号总量配额按它求和；同一账号相同内容只有一行，
-- 重复上传因此不重复计入。主键的前缀 (user_id) 已能支持按账号求和，另按
-- created_at 建索引供回填与排查时按时间列出。
CREATE TABLE attachment (
  user_id     TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  sha256      TEXT NOT NULL,
  size        BIGINT NOT NULL CHECK (size >= 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, sha256)
);
CREATE INDEX attachment_user_created ON attachment(user_id, created_at DESC);

