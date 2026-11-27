-- 知新 API 后端 · PostgreSQL 表结构（ADR-0009）
--
-- 开发阶段不写迁移（ADR-0001）：结构变化时直接按本文件整份重建库，重建会清空
-- 包括 app_user 在内的全部表（ADR-0057）。
-- 服务端不解析学习内容：同步变更、摘要、分表摘要与命名版本按客户端提交原样保存。
-- 同步一侧的表是 sync_state（每账号一行：head、保留下界与快照指针）、
-- sync_commit、sync_commit_seen、sync_device 与 sync_ref；旧快照的回收标记在
-- attachment.orphaned_at 上，不单独建表。

-- 一个账号对应一个人的学习数据，登录凭据与联系方式分开放：密码留在这里，
-- 登录方式（现在是邮箱）各在 user_identity 占一行（ADR-0038）。
CREATE TABLE app_user (
  id             TEXT PRIMARY KEY,
  password_hash  TEXT NOT NULL,                 -- argon2id，PHC 格式
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 登录方式：一个账号可以挂多种联系方式，一种联系方式只能属于一个账号。
-- kind 现在只有 email 一种取值，CHECK 与代码识别的种类一致；以后接手机号或微信
-- 时再放宽 CHECK 并新增登录入口，表本身不必改（ADR-0057 的改表口径）。identifier
-- 是规范化之后的值（邮箱转小写），判重与登录都按 (kind, identifier) 定位账号。
-- verified_at 为空表示这种登录方式还没有用验证码确认。
CREATE TABLE user_identity (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('email')),
  identifier   TEXT NOT NULL,
  verified_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kind, identifier)
);
-- 账号页按账号列出登录方式，每日清理按“有没有已验证的登录方式”筛账号。
CREATE INDEX user_identity_by_user ON user_identity(user_id, created_at);

-- 验证码按登录方式保存，不挂在账号上：还没有账号的邮箱也能先发一枚。每种用途、
-- 每种登录方式只保留最新一枚，只存 HMAC-SHA256（验证码只有六位，直接存哈希可以
-- 被穷举）。过期或输错次数达到上限时删除，重新发送时覆盖。kind 与 user_identity
-- 一样现在只有 email 一种取值。
CREATE TABLE auth_code (
  purpose     TEXT NOT NULL CHECK (purpose IN ('verify_contact', 'reset_password')),
  kind        TEXT NOT NULL CHECK (kind IN ('email')),
  identifier  TEXT NOT NULL,
  user_id     TEXT REFERENCES app_user(id) ON DELETE CASCADE,
  code_hash   TEXT NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (purpose, kind, identifier)
);
-- 删除账号时按 user_id 找到还没用掉的验证码；过期验证码的每日清理按 expires_at
-- 全表扫描，表在万行以下，不为它单建索引（审查 V4）。
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

-- 模型代理的接入密钥：给用户自己的脚本或第三方工具调用 /v1/llm 下的模型接口，
-- 不参与登录，也不持有学习数据（ADR-0063）。与访问令牌共用 Authorization: Bearer
-- 头，靠 zx_ 前缀、长度与末尾校验码区分；只存整个密钥的 SHA-256，prefix 只留前几位
-- 供列表与撤销时辨认。没有有效期列：密钥不过期，只能由用户显式撤销，撤销写
-- revoked_at 并保留这一行，列表里仍能看到它，撤销超过 30 天的行由每日清理删除。
-- 账号删掉时随外键级联删除；重设密码与刷新令牌重放检测都会撤销这个账号的全部密钥。
CREATE TABLE api_key (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  name         TEXT NOT NULL DEFAULT '',
  prefix       TEXT NOT NULL,
  key_hash     TEXT NOT NULL UNIQUE,
  revoked_at   TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 账号页按账号列出密钥，最近的在前；撤销按 (id, user_id) 定位，主键已经够用。
CREATE INDEX api_key_by_user ON api_key(user_id, created_at DESC);

-- 每个账号的同步状态与提交序列（ADR-0043）。推送时在同一事务里
-- SELECT ... FOR UPDATE 锁住这一行，核对 base_seq = head 之后再追加，压缩也在
-- 同一次事务里推进保留下界（ADR-0057 之前是单独的 sync_head，已并入本表）。
--
-- head 是最后分配的序号；trimmed_through 是已经删除到哪个序号，保留下界
-- （第一条仍可拉取的序号）等于它加一。快照指针的四个列同时可空：都为空表示还
-- 没有登记过快照；登记更新的位置时整行覆盖，字节是 attachments/<账号>/<sha256>。
CREATE TABLE sync_state (
  user_id              TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  head                 BIGINT NOT NULL DEFAULT 0,
  trimmed_through      BIGINT NOT NULL DEFAULT 0,
  snapshot_seq         BIGINT,
  snapshot_sha256      TEXT,
  snapshot_digest      TEXT,
  snapshot_created_at  TIMESTAMPTZ
);

-- 提交是一条流水账：uid 是客户端在用户动作发生时生成的提交身份（UUID 字符串），
-- 去重只按 sync_commit_seen 的主键，本表不再单独为 uid 建唯一约束（审查 V17）。
-- state_digest 与 table_digests 是客户端算出的整库摘要与分表摘要，服务端原样保存、
-- 不解析，拉取时原样带回（改进方案 3.5、ADR-0054）；没有带的提交存 NULL，响应里
-- 不出现这个键。
--
-- kind 只表示这条提交做了什么，取值与客户端的 revisionKinds 一致；来源只看
-- origin_device 一类字段，不设 remote 取值（审查 S23、V18）。
CREATE TABLE sync_commit (
  user_id         TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  seq             BIGINT NOT NULL,
  uid             TEXT NOT NULL,               -- 客户端提交身份，重试去重
  kind            TEXT NOT NULL CHECK (kind IN ('baseline', 'write', 'undo', 'restore', 'import', 'maintenance')),
  device_id       TEXT NOT NULL,
  schema_version  INTEGER NOT NULL,
  actor           TEXT NOT NULL CHECK (actor IN ('user', 'ai', 'system')),
  action          TEXT NOT NULL,
  created_at      TEXT NOT NULL,               -- 客户端时间，格式同 docs/01 D7
  received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  changes         JSONB NOT NULL,              -- [{table,row_key,op,before,after}]
  state_digest    TEXT,                        -- 客户端整库摘要，可选，原样保存不解析
  table_digests   JSONB,                       -- 表名到 64 位十六进制摘要的映射，可选，原样保存不解析
  PRIMARY KEY (user_id, seq)
);

-- 已经接收过的提交身份与它当时的序号。与 sync_commit 分开保存，压缩删掉旧提交
-- 之后仍然按它去重，整批重放时把重复提交原来的序号回给客户端（ADR-0040、
-- ADR-0054）；每行几十字节，不进入 256 MiB 的序列预算。
CREATE TABLE sync_commit_seen (
  user_id  TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  uid      TEXT NOT NULL,
  seq      BIGINT NOT NULL,
  PRIMARY KEY (user_id, uid)
);

-- 账号级设备名册（ADR-0048）：设备标识、用户设置的别名、快照能力、已经应用到的
-- 服务端序号与首次、最近出现时间。snapshot_capable 现在只有这一种能力，压缩门槛
-- 与设备位置门槛都按最近出现时间判断设备是否活跃（ADR-0054）。synced_seq 由带
-- X-Device-Id 的拉取与推送更新，不超过当前 head。清空云端数据时整表清掉，删号按
-- 外键级联。
CREATE TABLE sync_device (
  user_id           TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  device_id         TEXT NOT NULL,
  alias             TEXT NOT NULL DEFAULT '',
  snapshot_capable  BOOLEAN NOT NULL DEFAULT false,
  synced_seq        BIGINT NOT NULL DEFAULT 0,
  first_seen        TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);
-- 设备列表按最近出现时间倒序；压缩门槛按同一顺序找活跃设备。
CREATE INDEX sync_device_by_user_seen ON sync_device(user_id, last_seen DESC);

-- 账号级命名版本（ADR-0054）：名字指向一条提交的 uid，服务端只保存与转发，不解析。
-- 主键按 NFC 规范化之后的名字比较，名字最长 30 个字符，每账号最多 200 个未删除
-- 的名字。deleted_at 非空表示墓碑：删除之后名字在所有设备上消失，比删除时间更早
-- 的写入不会让它复活；墓碑不计入条数上限，永久保留。清空云端数据时整表清掉，
-- 删号按外键级联。
CREATE TABLE sync_ref (
  user_id     TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  commit_uid  TEXT NOT NULL,                   -- 这个名字指向的提交身份
  note        TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  PRIMARY KEY (user_id, name)
);
-- 主键的前导列已经能按账号列出全部名字，不再单建 (user_id) 索引（审查 V16）。

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

-- 模型代理用量：不记请求与回答正文。聊天与嵌入分开计，各有各的每日额度
-- （ADR-0029）。api_key_id 记录这次调用用的是哪把模型代理密钥，用访问令牌调用
-- 时是空字符串；它不是外键，撤销或清理密钥行不会带走已经发生的用量（ADR-0063）。
--
-- tokens 是计费 token：聊天按缓存命中折算（未命中输入 1、命中输入 1/50、输出 4），
-- 额度判定与已购余额都按它扣；input_tokens 与 cached_tokens 是上游报告的原始
-- 输入量与其中命中缓存的部分，只用于统计命中率，不参与扣减。嵌入没有缓存语义，
-- 三个数一致累加。折算口径见 server/internal/llmproxy/billing.go。
--
-- attempts 是这一天这个账号用这把密钥发出的尝试次数，failures 是其中失败、按 0
-- 结算的次数。两者只为让后台看见失败的调用：失败按 ADR-0070 记 0，tokens 与
-- reserved_tokens 都回到 0，只看 token 的话一把一直在失败的密钥与没有用过的密钥
-- 分不出来。它们不参与额度判定、预留与核销（ADR-0083）。
CREATE TABLE llm_usage (
  user_id       TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day           DATE NOT NULL,                  -- ZHIXIN_TIMEZONE 下的自然日
  kind          TEXT NOT NULL DEFAULT 'chat' CHECK (kind IN ('chat', 'embedding')),
  api_key_id    TEXT NOT NULL DEFAULT '',
  tokens        BIGINT NOT NULL DEFAULT 0,      -- 聊天计费 token，或嵌入原始 token
  reserved_tokens BIGINT NOT NULL DEFAULT 0,    -- 聊天在途预留
  embedding_billed_tokens BIGINT NOT NULL DEFAULT 0,   -- 嵌入已结算的共享额度用量
  embedding_reserved_tokens BIGINT NOT NULL DEFAULT 0, -- 嵌入在途预留的计费 token
  input_tokens  BIGINT NOT NULL DEFAULT 0,      -- 上游报告的输入量
  cached_tokens BIGINT NOT NULL DEFAULT 0,      -- 其中命中缓存的部分
  attempts      BIGINT NOT NULL DEFAULT 0,      -- 尝试次数，含失败
  failures      BIGINT NOT NULL DEFAULT 0,      -- 其中失败、按 0 结算的次数
  PRIMARY KEY (user_id, day, kind, api_key_id)
);

-- 实例当天的模型用量：只有自然日与计费 token 数，不与账号关联，删号与清空云端
-- 数据都不会减少它。实例日预算据此判断，删号因此不会把已经发生的提供方费用重新
-- 变成可用额度（ADR-0036）。
CREATE TABLE llm_instance_usage (
  day     DATE PRIMARY KEY,                     -- ZHIXIN_TIMEZONE 下的自然日
  tokens  BIGINT NOT NULL DEFAULT 0
);

-- 结算失败、等待补退的预留（ADR-0086）。结算在事务里失败时写一行，之后补退预留与
-- 删除这一行在同一个事务里完成。reserved_tokens 只有结算会减，结算失败之后如果没有
-- 这份记录，那笔预留再也没有人退，当天的额度就一直被白占，而 `GET /v1/llm/quota`
-- 只显示已结算用量，用户看到的是“没用多少却一直 429”。下一次请求按账号补退，全局
-- 补查按创建时间兜底；账号删除时随外键级联，账号不在了也不需要把这笔额度退给谁。
CREATE TABLE llm_settlement_failure (
  id              TEXT PRIMARY KEY DEFAULT replace(gen_random_uuid()::text, '-', ''),
  user_id         TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day             DATE NOT NULL,                -- ZHIXIN_TIMEZONE 下的自然日
  kind            TEXT NOT NULL CHECK (kind IN ('chat', 'embedding')),
  api_key_id      TEXT NOT NULL DEFAULT '',
  reserved_tokens BIGINT NOT NULL CHECK (reserved_tokens > 0),
  billed_tokens   BIGINT NOT NULL DEFAULT 0,    -- 这次没有记进已结算用量的计费 token
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 行在补退成功时立即删除，这张表正常时是空的，两个索引都不留长期成本：
-- 下一次请求先按账号补退，再判断额度；全局补查按创建时间取最早的一批。
CREATE INDEX llm_settlement_failure_user_idx ON llm_settlement_failure (user_id, created_at);
CREATE INDEX llm_settlement_failure_created_idx ON llm_settlement_failure (created_at);

-- 结算之后还没有申请核销的用量（ADR-0087）。结算把用量提交进 llm_usage，申请核销
-- 另起一步，进程在两步之间退出、或者申请那一步读失败时，这一段用量只有当天之后的
-- 结算按累计差额补；跨日之后没有结算再写这一天，用量就收不到了。结算事务里同时写
-- 下这一天该收的计费 token，每十分钟一次的补查按它重新申请，收齐之后删除。
CREATE TABLE llm_charge_pending (
  user_id           TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day               DATE NOT NULL,              -- ZHIXIN_TIMEZONE 下的自然日
  chargeable_tokens BIGINT NOT NULL CHECK (chargeable_tokens > 0),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, day)
);
-- 补查按创建时间取最早的一批；行在收齐之后立即删除，正常时这张表接近空的。
CREATE INDEX llm_charge_pending_created_idx ON llm_charge_pending (created_at);

-- 每条模型路由的每日汇总，与账号额度各自记录。
--
-- input_tokens 与 cached_tokens 是合计；first_* 与 failover_* 是同一组数字按
-- “这次请求实际执行的第一条路由”与“此前的尝试失败后接手的路由”拆开的两栏。
-- *_reports 是上报条数：input_reports 记来源给了 input_tokens 的尝试数，
-- cached_reports 记其中也给了 cached_tokens 的尝试数。来源报了 0 与来源没有这个
-- 字段是两件事，前者算零命中，后者只增加两者的差额（上游缺报），因此命中率与
-- 上报覆盖率要分开算。
CREATE TABLE llm_route_usage (
  day               DATE NOT NULL,
  kind              TEXT NOT NULL CHECK (kind IN ('chat', 'embedding')),
  model             TEXT NOT NULL,
  provider_id       TEXT NOT NULL,
  upstream_model    TEXT NOT NULL,
  attempts          BIGINT NOT NULL,
  first_attempts    BIGINT NOT NULL,
  failover_attempts BIGINT NOT NULL,
  successes         BIGINT NOT NULL,
  truncated_attempts BIGINT NOT NULL,
  canceled_attempts BIGINT NOT NULL,
  tokens            BIGINT NOT NULL,
  estimated_tokens  BIGINT NOT NULL,
  input_tokens      BIGINT NOT NULL,
  cached_tokens     BIGINT NOT NULL,
  first_input_tokens      BIGINT NOT NULL,
  first_cached_tokens     BIGINT NOT NULL,
  failover_input_tokens   BIGINT NOT NULL,
  failover_cached_tokens  BIGINT NOT NULL,
  first_input_reports     BIGINT NOT NULL,
  first_cached_reports    BIGINT NOT NULL,
  failover_input_reports  BIGINT NOT NULL,
  failover_cached_reports BIGINT NOT NULL,
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

-- 登录账号的活跃：一行是一天，按服务端收到的请求日期记（ADR-0019）。保留期的
-- 每日清理按 day 全表扫描，表在万行以下，不为它单建索引（审查 V4）。
CREATE TABLE user_active (
  user_id  TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  day      DATE NOT NULL,                      -- ZHIXIN_TIMEZONE 下的自然日
  PRIMARY KEY (user_id, day)
);

-- 未登录设备的匿名活跃：只保存安装标识的 HMAC-SHA256 与日期，原始标识不落库；
-- 按 180 天滚动删除（ADR-0019）。保留期的每日清理按 day 全表扫描，表在万行以下，
-- 不为它单建索引（审查 V4）。
CREATE TABLE install_active (
  install_hash  TEXT NOT NULL,
  day           DATE NOT NULL,
  app_version   TEXT NOT NULL DEFAULT '',
  platform      TEXT NOT NULL DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (install_hash, day)
);

-- 按账号调整每日模型额度：没有行或者某一列为空时用 ZHIXIN_LLM_DAILY_TOKENS
-- 与 ZHIXIN_LLM_EMBEDDING_DAILY_TOKENS。管理后台的账号管理页读写这张表，下一次
-- 模型请求生效，不重启服务；后台不可用时仍可直接改库（ADR-0078）。
CREATE TABLE llm_quota (
  user_id                 TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  daily_tokens            BIGINT CHECK (daily_tokens > 0),
  note                    TEXT NOT NULL DEFAULT '',
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 即刻收积分核销流水（ADR-0067）。id 同时是提交给即刻收的 out_request_no：结果
-- 未知时只能用原号查询或重试，换号会多扣一次，所以幂等号必须落在本地。points 按
-- 「1 积分 = 配置的计费 token 数」向上取整折算，只对超出免费额度的部分申请；
-- status 为 failed 的流水不再计入当天已申请量，下一次结算重新算差额。账号删除时
-- 解除关联而不删行，留作对账。终态行的 updated_at 视为确认时间，副本据此判断哪些
-- 核销还没有被余额快照反映（ADR-0073）。
--
-- claimed_at 是发送核销之前的本地认领时刻（ADR-0088）：同一笔流水可能被请求前的
-- 补查、十分钟一次的全局补查与写流水之后的入队各排一次，发送之前用
-- “status 仍是 pending 且认领已过期”的条件把同一时刻的发送收成一次。状态不因此
-- 改成 processing，因为请求可能根本没有发出去，标成 processing 之后只能按请求号
-- 查结果，查不到就一直停在那里。
--
-- attempts 与 last_attempt_at 是全局补查的尝试次数与上一次尝试时刻（ADR-0089）：
-- 补查按上一次尝试时刻轮转取数，反复失败的流水试过一次就排到后面，更晚的流水不会
-- 被最老的一批挤掉。attempts 超过上限的流水落成 abandoned，不再重试；它不记 failed，
-- 因为 failed 不计入当天已申请量，下一次结算会按差额重新申请，可能重复扣款。abandoned
-- 在本地按“已经申请”处理，保留期与 failed、succeeded 一样按更新时间清理。
CREATE TABLE nowpay_charge (
  id            TEXT PRIMARY KEY,
  user_id       TEXT REFERENCES app_user(id) ON DELETE SET NULL,
  day           DATE NOT NULL,
  points        BIGINT NOT NULL CHECK (points > 0),
  billed_tokens BIGINT NOT NULL CHECK (billed_tokens > 0),
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'processing', 'succeeded', 'failed', 'abandoned')),
  note          TEXT NOT NULL DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at    TIMESTAMPTZ,
  attempts      INT NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_attempt_at TIMESTAMPTZ
);
CREATE INDEX nowpay_charge_user_day_idx ON nowpay_charge (user_id, day);
CREATE INDEX nowpay_charge_unsettled_idx
  ON nowpay_charge (user_id, created_at) WHERE status IN ('pending', 'processing');
-- 全局补查按上一次尝试时刻取还没有终结的流水，不按账号过滤，见运维手册的补查与
-- 保留期。从没尝试过的流水排在最前（NULLS FIRST），反复失败的一次就排到后面。
CREATE INDEX nowpay_charge_retry_idx
  ON nowpay_charge (last_attempt_at NULLS FIRST, created_at)
  WHERE status IN ('pending', 'processing');

-- 购买入口请求（ADR-0067、ADR-0074）。一行对应客户端的一次点击：client_request_no
-- 是客户端生成的幂等键，同一次点击的重试复用它，换一次点击换一个键。state 为
-- creating 时 purchase_url 为空，purchase.create 成功之后转 ready 并写真实有效期，
-- 失败或超时转 failed 并保留原 out_request_no 供重试；同一键重新生成入口时替换整行。
-- 账号删除时解除关联而不删行，留作对账。
CREATE TABLE nowpay_purchase (
  out_request_no    TEXT PRIMARY KEY,
  client_request_no TEXT NOT NULL DEFAULT '',
  user_id           TEXT REFERENCES app_user(id) ON DELETE SET NULL,
  sku_id            TEXT NOT NULL DEFAULT '',
  state             TEXT NOT NULL DEFAULT 'ready'
                    CHECK (state IN ('creating', 'ready', 'failed')),
  purchase_url      TEXT,
  expires_at        TIMESTAMPTZ NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX nowpay_purchase_user_created_idx
  ON nowpay_purchase (user_id, created_at DESC) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX nowpay_purchase_client_request_idx
  ON nowpay_purchase (user_id, client_request_no)
  WHERE user_id IS NOT NULL AND client_request_no <> '';

-- 即刻收积分余额的本地副本（ADR-0069、ADR-0073）。额度预留按免费额度之外的这份
-- 余额放行，请求路径上因此不必调用即刻收：查询余额、购买页刷新与每次核销的结果都
-- 覆盖 remaining_points 与 synced_at。synced_at 是这份余额对应的快照时刻，不是写入
-- 时刻；晚到的旧快照不会覆盖新副本。它是缓存而不是账本，账号删除时一并删除；真正
-- 的余额在支付宝一侧，这里只用于判断能不能放行。
CREATE TABLE nowpay_balance (
  user_id          TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  remaining_points BIGINT NOT NULL CHECK (remaining_points >= 0),
  synced_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 附件索引：字节在对象存储的 attachments/<user_id>/<sha256>，这张表只记“这个
-- 账号有这份内容、占多少字节”。账号总量配额按它求和；同一账号相同内容只有一行，
-- 重复上传因此不重复计入。主键的前缀 (user_id) 已能支持按账号求和，不再为回填与
-- 排查单建 created_at 索引（审查 V6）。
--
-- orphaned_at 记旧快照让位的时间（ADR-0047、审查 V2）：快照指针换成另一个哈希时
-- 旧哈希这一行标记，同一哈希重复让位保留最早的时间，指针重新使用某个哈希时置空。
-- 回收删除 orphaned_at 早于宽限期、且不是当前快照指针的行：先删对象字节，再删
-- 索引行。待回收的行仍然计入账号总量，与“删除之前仍占空间”的口径一致。
CREATE TABLE attachment (
  user_id      TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  sha256       TEXT NOT NULL,
  size         BIGINT NOT NULL CHECK (size >= 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  orphaned_at  TIMESTAMPTZ,
  PRIMARY KEY (user_id, sha256)
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
  -- 能力标记：管理员按实际调用核对过才保留为 true，请求带图片或工具声明时只走
  -- 具备对应能力的候选。默认按支持处理，与加筛选之前的行为一致。
  supports_tools  BOOLEAN NOT NULL DEFAULT true,
  supports_images BOOLEAN NOT NULL DEFAULT true,
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
-- 管理后台删除模型或改变维度时按模型删除：全表扫描，不再为它单建索引（审查 V5）。

-- 嵌入向量缓存的清除代次：清空云端数据时加一，之前发出的嵌入请求即使之后才写
-- 缓存，也因为代次对不上而被丢弃（ADR-0037）。账号删除时随外键级联。
CREATE TABLE embedding_cache_generation (
  user_id     TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  generation  BIGINT NOT NULL DEFAULT 0
);

