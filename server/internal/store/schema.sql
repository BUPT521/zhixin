-- 知新 API 后端 · PostgreSQL 表结构草案（ADR-0009）
--
-- 开发阶段不写迁移（ADR-0001）：结构变化时直接按本文件重建库。
-- 服务端不解析学习内容：同步变更与备份按客户端提交原样保存。

-- 一个账号对应一个人的学习数据，登录凭据与联系方式分开放：密码留在这里，
-- 邮箱、手机号、微信这类“登录方式”各在 user_identity 占一行（ADR-0038）。
CREATE TABLE app_user (
  id             TEXT PRIMARY KEY,
  password_hash  TEXT NOT NULL,                 -- argon2id，PHC 格式
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 登录方式：一个账号可以挂多种联系方式，一种联系方式只能属于一个账号。
-- kind 的取值先留好 email、phone、wechat 三种，代码现在只写 email；以后接手机号
-- 或微信，只需新增一种 kind 与对应的登录入口，不用再改这张表。identifier 是
-- 规范化之后的值（邮箱转小写），判重与登录都按 (kind, identifier) 定位账号。
-- verified_at 为空表示这种登录方式还没有用验证码确认。
CREATE TABLE user_identity (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('email', 'phone', 'wechat')),
  identifier   TEXT NOT NULL,
  verified_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kind, identifier)
);
-- 账号页按账号列出登录方式，每日清理按“有没有已验证的登录方式”筛账号。
CREATE INDEX user_identity_by_user ON user_identity(user_id, created_at);

-- 验证码按登录方式保存，不挂在账号上：还没有账号的邮箱或手机号也能先发一枚。
-- 每种用途、每种登录方式只保留最新一枚，只存 HMAC-SHA256（验证码只有六位，
-- 直接存哈希可以被穷举）。过期或输错次数达到上限时删除，重新发送时覆盖。
CREATE TABLE auth_code (
  purpose     TEXT NOT NULL CHECK (purpose IN ('verify_contact', 'reset_password')),
  kind        TEXT NOT NULL CHECK (kind IN ('email', 'phone', 'wechat')),
  identifier  TEXT NOT NULL,
  user_id     TEXT REFERENCES app_user(id) ON DELETE CASCADE,
  code_hash   TEXT NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (purpose, kind, identifier)
);
-- 每日清理过期验证码按 expires_at 扫。
CREATE INDEX auth_code_by_expires ON auth_code(expires_at);
-- 删除账号时按 user_id 找到还没用掉的验证码。
CREATE INDEX auth_code_by_user ON auth_code(user_id);

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
-- 登录时锁住账号行、按创建时间倒序只保留最新的若干条，会话上限因此不受并发
-- 影响；user_id 上的这条复合索引同时承担按账号查会话的查询。
CREATE INDEX session_by_user ON session(user_id, created_at DESC);
-- 每日清理过期会话按 refresh_expires 扫。
CREATE INDEX session_by_refresh_expires ON session(refresh_expires);

-- 已经轮换掉的刷新令牌摘要。旧令牌再次出现时，服务层用它区分“同一客户端的
-- 重试”与“令牌被复制”：宽限期固定 60 秒，重试不延长。只存摘要，不存令牌本身；
-- 会话删掉时这些记录跟着删（ON DELETE CASCADE）。
CREATE TABLE session_refresh_used (
  token_hash            TEXT PRIMARY KEY,
  session_id            TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  user_id               TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  request_id            TEXT NOT NULL DEFAULT '',
  rotated_at            TIMESTAMPTZ NOT NULL,
  grace_until           TIMESTAMPTZ NOT NULL,
  replaced_access_hash  TEXT NOT NULL,          -- 本次轮换发出的访问令牌摘要
  replaced_refresh_hash TEXT NOT NULL           -- 本次轮换发出的刷新令牌摘要
);
CREATE INDEX session_refresh_used_session ON session_refresh_used(session_id);
CREATE INDEX session_refresh_used_rotated_at ON session_refresh_used(rotated_at);

-- 每个账号一条线性提交序列。推送时在同一事务里 SELECT ... FOR UPDATE
-- 锁住 sync_head，核对 base_seq = head 之后再追加。
-- trimmed_through 是已经删除到哪个序号：压缩删掉快照覆盖的旧提交之后推进，
-- 保留下界（第一条仍可拉取的序号）等于它加一（ADR-0043）。
CREATE TABLE sync_head (
  user_id          TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  head             BIGINT NOT NULL DEFAULT 0,
  trimmed_through  BIGINT NOT NULL DEFAULT 0
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
  state_digest    TEXT,                        -- 客户端整库摘要，可选，原样保存不解析（改进方案 3.5）
  PRIMARY KEY (user_id, seq),
  UNIQUE (user_id, request_id)
);

-- 账号当前快照的指针，每个账号最多一行；字节是 attachments/<账号>/<sha256>。
-- 只保留最新一份，登记更新的位置时整行覆盖（ADR-0043）。
CREATE TABLE sync_snapshot (
  user_id     TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  seq         BIGINT NOT NULL,
  sha256      TEXT NOT NULL,
  digest      TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 已经接收过的提交身份。与 sync_commit 分开保存，压缩删掉旧提交之后仍然按它
-- 去重（ADR-0040 的永久去重）；每行几十字节，不进入 256 MiB 的序列预算。
CREATE TABLE sync_commit_seen (
  user_id     TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  request_id  TEXT NOT NULL,
  PRIMARY KEY (user_id, request_id)
);

-- 被新快照替换下来的旧附件，按宽限期回收（ADR-0047）。每行是账号、附件哈希与
-- 让位时间；同一哈希重复让位时保留最早的 orphaned_at，新指针哈希重新投入使用时
-- 删掉这一行，回收时还要排除当前指针。清空云端数据时整表清掉，删号按外键级联。
CREATE TABLE sync_snapshot_orphan (
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  sha256       TEXT NOT NULL,
  orphaned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, sha256)
);
-- 回收按账号找早于宽限期的行。
CREATE INDEX sync_snapshot_orphan_by_user_time ON sync_snapshot_orphan(user_id, orphaned_at);

-- 账号级设备名册（ADR-0048）：设备标识、用户设置的别名、能力声明与首次、最近
-- 出现时间。capabilities 是逗号分隔的小写能力名，当前只有 snapshot；压缩门槛
-- 按最近出现时间判断设备是否活跃。清空云端数据时整表清掉，删号按外键级联。
CREATE TABLE sync_device (
  user_id       TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  device_id     TEXT NOT NULL,
  alias         TEXT NOT NULL DEFAULT '',
  capabilities  TEXT NOT NULL DEFAULT '',
  first_seen    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);
-- 设备列表按最近出现时间倒序；压缩门槛按同一顺序找活跃设备。
CREATE INDEX sync_device_by_user_seen ON sync_device(user_id, last_seen DESC);

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

-- 模型代理用量：只记 token 数，不记请求与回答正文。聊天与嵌入分开计，
-- 各有各的每日额度（ADR-0029）。
CREATE TABLE llm_usage (
  user_id  TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day      DATE NOT NULL,                      -- ZHIXIN_TIMEZONE 下的自然日
  kind     TEXT NOT NULL DEFAULT 'chat' CHECK (kind IN ('chat', 'embedding')),
  tokens   BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day, kind)
);

-- 实例当天的模型用量：只有自然日与 token 数，不与账号关联，删号与清空云端数据
-- 都不会减少它。实例日预算据此判断，删号因此不会把已经发生的提供方费用重新变成
-- 可用额度（ADR-0036）。
CREATE TABLE llm_instance_usage (
  day     DATE PRIMARY KEY,                     -- ZHIXIN_TIMEZONE 下的自然日
  tokens  BIGINT NOT NULL DEFAULT 0
);

-- 每条模型路由的每日汇总，与账号额度各自记录。
CREATE TABLE llm_route_usage (
  day               DATE NOT NULL,
  kind              TEXT NOT NULL CHECK (kind IN ('chat', 'embedding')),
  model             TEXT NOT NULL,
  provider_id       TEXT NOT NULL,
  upstream_model    TEXT NOT NULL,
  attempts          BIGINT NOT NULL,
  successes         BIGINT NOT NULL,
  tokens            BIGINT NOT NULL,
  estimated_tokens  BIGINT NOT NULL,
  PRIMARY KEY (day, kind, model, provider_id, upstream_model)
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

-- 按账号调整每日模型额度：没有行或者某一列为空时用 ZHIXIN_LLM_DAILY_TOKENS
-- 与 ZHIXIN_LLM_EMBEDDING_DAILY_TOKENS。管理员直接写这张表调整个别账号，不重启
-- 服务。
CREATE TABLE llm_quota (
  user_id                 TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  daily_tokens            BIGINT CHECK (daily_tokens > 0),
  embedding_daily_tokens  BIGINT CHECK (embedding_daily_tokens > 0),
  note                    TEXT NOT NULL DEFAULT '',
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
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

-- 清除云端数据的进行中标记：一行表示这个账号正在清除（或上次清除中途失败）。
-- 清除开始写入 started_at，结束时删除行；超过 10 分钟的标记视为上次中断，新的
-- 请求接管并从头重做各步。清除期间写请求据此返回 409。账号删除时级联删除。
CREATE TABLE user_purge (
  user_id     TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  started_at  TIMESTAMPTZ NOT NULL
);

-- 模型来源：一个 OpenAI 兼容的基础地址与一把 key，由管理后台维护（ADR-0029、
-- ADR-0035）。key 只存 AES-256-GCM 密文，密钥是环境变量 ZHIXIN_SECRET_KEY，
-- 不在库里；key_hint 是末四位，列表不用解密。
CREATE TABLE llm_provider (
  id             TEXT PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name           TEXT NOT NULL DEFAULT '',
  base_url       TEXT NOT NULL,
  api_key_sealed TEXT NOT NULL DEFAULT '',
  key_hint       TEXT NOT NULL DEFAULT '',
  enabled        BOOLEAN NOT NULL DEFAULT true,
  note           TEXT NOT NULL DEFAULT '',
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 对外模型：客户端请求里写的名字。dimensions 只用于嵌入模型。
CREATE TABLE llm_model (
  name        TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('chat', 'embedding')),
  enabled     BOOLEAN NOT NULL DEFAULT true,
  dimensions  INTEGER CHECK (dimensions BETWEEN 1 AND 8192),
  note        TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 路由：对外模型到某个来源上的模型名。priority 小的先试，同一优先级按 weight
-- 分流；max_batch 是嵌入一次发给来源的最多条数，0 表示不拆分。删除来源前要先
-- 删掉指向它的路由，所以外键不级联。
CREATE TABLE llm_route (
  model           TEXT NOT NULL REFERENCES llm_model(name) ON DELETE CASCADE,
  provider_id     TEXT NOT NULL REFERENCES llm_provider(id),
  upstream_model  TEXT NOT NULL,
  priority        INTEGER NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 100),
  weight          INTEGER NOT NULL DEFAULT 1 CHECK (weight BETWEEN 1 AND 1000),
  max_batch       INTEGER NOT NULL DEFAULT 0 CHECK (max_batch BETWEEN 0 AND 2048),
  enabled         BOOLEAN NOT NULL DEFAULT true,
  position        INTEGER NOT NULL,              -- 管理后台里的排列顺序
  PRIMARY KEY (model, provider_id, upstream_model)
);
CREATE INDEX llm_route_provider ON llm_route(provider_id);

-- 嵌入向量缓存：按账号、对外模型与文本哈希保存已经算过的向量（ADR-0030）。
-- 检索索引由客户端维护，服务端只承担“模型与文本到向量”这一层；缓存是派生数据，
-- 可以从业务库与嵌入服务重建，不进入数据包与整库备份。向量是小端序 FP16，dim
-- 是分量数，长度由 CHECK 与 dim 绑定。只给自动同步开启、且这次是索引刷新的嵌入
-- 请求写入；每账号的字节上限由 ZHIXIN_LLM_EMBEDDING_CACHE_BYTES 控制，写入之后
-- 按 last_used_at 删除最久未用的行，命中时同一条语句更新 last_used_at。
CREATE TABLE embedding_cache (
  user_id       TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  model         TEXT NOT NULL,                     -- 对外模型名
  text_hash     TEXT NOT NULL CHECK (text_hash ~ '^[0-9a-f]{64}$'),
  dim           INTEGER NOT NULL CHECK (dim BETWEEN 1 AND 8192),
  vector        BYTEA NOT NULL CHECK (octet_length(vector) = dim * 2),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, model, text_hash)
);
-- 上限清理按账号与 last_used_at 扫，命中时按批更新 last_used_at。
CREATE INDEX embedding_cache_by_user_used ON embedding_cache(user_id, last_used_at);
-- 管理后台删除模型或改变维度时按模型删除。
CREATE INDEX embedding_cache_by_model ON embedding_cache(model);

-- 嵌入向量缓存的清除代次：清空云端数据时加一，之前发出的嵌入请求即使之后才写
-- 缓存，也因为代次对不上而被丢弃（ADR-0037）。账号删除时随外键级联。
CREATE TABLE embedding_cache_generation (
  user_id     TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  generation  BIGINT NOT NULL DEFAULT 0
);

