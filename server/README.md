# 知新 · API 后端

> 本目录是知新的自建 API 服务，第一期负责账号与登录、整库备份与增量同步、模型请求代理（聊天与嵌入，可以配置多个来源），另外提供应用内的更新检查与反馈接口，以及管理模型来源的后台。为什么要有服务端、它不负责什么，见 [ADR-0008](../docs/adr/0008-取消单机边界引入账号同步与模型代理.md)；为什么用 Go、怎样分层，见 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md)。接口以 [api/openapi.yaml](api/openapi.yaml) 为准，本文只说明工程结构、约定与本地运行。

## 当前状态

路由由 `api/openapi.yaml` 经 `oapi-codegen` 生成到 `internal/api/`，`internal/server/routes.go` 只把生成的路由转发给各业务包的处理器；契约改了而转发没跟上时编译失败。账号、登录方式验证与找回密码、提交序列的推送、拉取、快照登记与压缩（`/v1/sync/snapshot`，[ADR-0043](../docs/adr/0043-服务端快照登记与提交序列压缩.md)）、整库备份的上传下载与保留份数、附件的上传下载与存在检查、模型代理的转发与额度都已经按契约实现。应用内的更新检查与反馈接口也已经在 2026-11-18 实现：`GET /v1/app/releases` 公开返回发布清单，`POST /v1/feedback` 公开接收反馈并写入 `feedback` 表，两者都不需要登录，取舍见 [ADR-0025](../docs/adr/0025-应用内更新检查与反馈的接口口径.md)。留存统计的服务端部分同日完成：登录账号按服务端收到的请求日期记活跃，未登录设备通过 `POST /v1/telemetry/active` 匿名上报，安装标识只保存 HMAC-SHA256，匿名数据按 180 天滚动删除；模型额度也支持按账号单独调整（`llm_quota` 表），调整不用重启服务（[留存统计](#留存统计)、[模型代理](#模型代理)）。存储分两种：不设 `ZHIXIN_DATABASE_URL` 时全部在内存里，进程退出后数据丢失，只能用于本地开发与联调；设置之后账号、会话、提交序列、备份元数据、反馈、活跃数据与用量入库（`internal/store/pg`，查询由 `sqlc` 从 `internal/store/queries` 生成），字节放对象存储（`internal/objectstore`）：设了 `ZHIXIN_S3_ENDPOINT` 用 S3 兼容存储，没设时落到 `ZHIXIN_BLOB_DIR` 指定的本地目录，进程重启都不丢。首次在空库上启动时设 `ZHIXIN_APPLY_SCHEMA=1`，服务会按 `internal/store/schema.sql` 建表，建完可以去掉。附件按内容寻址，服务端核对 SHA-256 之后保存，单个上限见配置表的 `ZHIXIN_MAX_ATTACHMENT_BYTES`，一个账号的全部附件另有总量上限 `ZHIXIN_MAX_ACCOUNT_ATTACHMENT_BYTES`，超限时上传返回 413 `storage_full`。

2026-11-18 的加固轮次把服务端的默认行为收紧：启动时自检生产配置（配置了数据库时验证码不能写进日志、验证码与匿名统计的 HMAC 密钥必须固定、带凭据的上游地址必须走 https），公开写入接口在按地址的桶之外增加全局上限，反馈按保留期每日清理，登录失败按规范化的登录方式计预算，密码哈希受 Argon2 内存预算约束，每个账号的会话数有上限并在每天清理过期会话，刷新令牌轮换后只保留固定 60 秒的重试宽限，附件增加账号总量配额，清除云端数据统一为 `DELETE /v1/cloud`，模型代理增加未验证登录方式拒绝、账号并发上限、响应体上限、额度预留与实例总预算，发布清单要求 HTTPS、SHA-256 和 Ed25519 签名。配置项见下表，跨模块取舍与代价见 [ADR-0028](../docs/adr/0028-服务端加固的默认拒绝与预算.md) 和 [ADR-0031](../docs/adr/0031-云端写入与托管模型的资源预算.md)。

2026-11-20 的加固轮次补上了四处写路径的窗口：嵌入缓存按账号记代次，清除云端数据之后，清除之前发出的嵌入请求写不回旧向量；刷新令牌的轮换与重放记录在同一个事务或同一把锁里完成；备份对象每小时窗口之外由后台对账清理没有元数据的遗留字节；注册增加实例级上限，超过保留期仍没有任何已验证登录方式的账号由每日清理删除。取舍与代价见 [ADR-0037](../docs/adr/0037-遗留写路径与公开入口的加固.md)。

`schema.sql` 在 2026-11-17 增加了 `auth_code` 表与 `app_user.email_verified_at`，在 2026-11-18 增加了 `feedback`、`user_active`、`install_active` 与 `llm_quota` 四张表，同日的加固轮次又增加了 `attachment`、`user_purge` 与 `session_refresh_used` 三张表与相应索引。模型路由增加了 `llm_provider`、`llm_model` 与 `llm_route`，并按用途记录 `llm_usage` 与额度覆盖值，用途见[表结构](#表结构)。开发阶段不写迁移（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)），已有实例按当前 `schema.sql` 重建库；当时实例里只有联调数据。2026-11-19 又增加了 `embedding_cache` 表，保存按账号隔离的嵌入向量缓存（[ADR-0030](../docs/adr/0030-服务端不建检索索引.md) 第一步）。2026-11-20 增加 `llm_instance_usage`，把实例当天的模型用量从账号用量里分出来，删号不再减少实例预算（[ADR-0036](../docs/adr/0036-实例模型预算与账号用量分开.md)）。同日还增加 `embedding_cache_generation`，记录每个账号的缓存代次，清空云端数据时加一，清除之前发出的嵌入请求因此写不回旧向量（[ADR-0037](../docs/adr/0037-遗留写路径与公开入口的加固.md)）。2026-11-20 又把账号与登录方式拆开：`app_user` 只保留 `id`、`password_hash` 与 `created_at`，邮箱移进新表 `user_identity`，`auth_code` 的主键换成（用途，kind，identifier）且 `user_id` 允许为空（[ADR-0038](../docs/adr/0038-账号与登录方式分开.md)）。

模型代理按优先级与权重从多个来源选择路由，嵌入接口按路由配置拆批，聊天与嵌入分别计入账号额度。模型来源与路由可在[管理后台](#管理后台)配置，取舍见 [ADR-0029](../docs/adr/0029-模型来源路由与嵌入代理.md)。

服务端按 [ADR-0030](../docs/adr/0030-服务端不建检索索引.md) 的第一步实现了嵌入向量缓存与查找接口：检索索引仍由客户端维护，服务端只承担“模型与文本到向量”这一层，换机、索引重建与切换模型时先查缓存、只补算未命中的片段。`POST /v1/llm/embeddings/lookup` 按账号与对外模型返回已经算过的向量，`POST /v1/llm/embeddings` 带 `X-Zhixin-Embedding-Cache: 1` 时写入缓存；缓存按账号隔离、有字节上限，随清除云端数据与删除账号一起删除。客户端已于同日接入：索引刷新先按 SHA-256 归并相同片段，再调查找接口取回命中的向量，只嵌入未命中的部分；写缓存标记只在登录且自动同步开启时带上。旧版客户端不调用查找接口，行为不变。

CI 使用临时 PostgreSQL 实例执行服务端存储测试；在开发机上可以设置 `ZHIXIN_TEST_DATABASE_URL` 执行同一组用例，连接串须指向允许重建表的专用测试库。

账号保留时可以单独清空云端数据：`DELETE /v1/cloud` 依次删除该账号的全部备份、提交序列、附件与对象存储里遗留的字节，成功返回 204，可重复调用，中途失败时重试从剩下的部分继续；清除期间这个账号的写入请求返回 409 `conflict`，客户端退避之后重试，账号、会话与本机数据都不受影响。原来的 `DELETE /v1/backups` 与 `DELETE /v1/sync/commits` 仍然保留，分别清空备份与提交序列；客户端设置页的“清除云端数据”改为调用 `DELETE /v1/cloud`，并在完成后显示状态、询问是否恢复自动同步。

第一套实例已经在一台单机 Debian 13 上跑起来，备份与附件的字节放阿里云 OSS 的 S3 兼容接口，部署方式见[部署与凭据](#部署与凭据)。客户端已经接入登录、登录方式验证、找回密码、整库备份、按提交的增量同步与“知新服务”模型来源，首次同步只上传云端还没有的行的取舍见 [ADR-0023](../docs/adr/0023-首次同步上传基线.md) 与[改进方案 3.6](../docs/数据版本系统对照git的改进方案.md)。更新检查与反馈的服务端接口也于 2026-11-18 就绪，应用内的提示与入口由吴闻杰在 M1 接入；接下来的顺序是两台设备的同步走查与限额调整。登录方式验证与找回密码按 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md) 第 5 条已经落地。

PostgreSQL 存取用 `pgx` 加 `sqlc` 生成，契约用 `oapi-codegen` 生成并挂到标准库路由上，登录与刷新令牌用 `golang.org/x/time/rate` 限流，对象存储用 `minio-go` 访问，依赖清单与理由见 [ADR-0015](../docs/adr/0015-服务端引入代码生成与限流依赖.md) 与 [ADR-0016](../docs/adr/0016-对象存储与附件接口.md)。生成代码与客户端一样提交入库，提交前重新生成并核对没有差异；生成命令在 `server/` 目录下执行，`api/cfg.yaml` 里的输出路径相对这个目录：

```bash
cd server
go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.2 -config api/cfg.yaml api/openapi.yaml
go run github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1 generate
```

## 表结构

服务端 PostgreSQL 的表与索引以 [internal/store/schema.sql](internal/store/schema.sql) 为唯一真相，本节只说明用途；客户端本机 SQLite 的表在 [01](../docs/01-ER数据模型.md)，两份文档不互相复制。开发阶段不写迁移（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)），结构变化时按当前文件重建库。

2026-11-18 的加固轮次新增了三张表：

| 表 | 用途 | 关键列与约束 |
|---|---|---|
| `attachment` | 附件索引，按账号与内容哈希去重，用于账号附件总量配额与回填 | `user_id` 外键级联删除，`sha256`、`size`，主键 `(user_id, sha256)`；对象字节仍在 `attachments/<账号>/<sha256>`，删号时按前缀清理 |
| `user_purge` | `DELETE /v1/cloud` 的清除标记，存在时该账号的写入返回 409 | `user_id` 主键，`started_at`；超过十分钟视为中断，可以接管重做 |
| `session_refresh_used` | 已用刷新令牌的摘要与重试宽限，支撑轮换与 60 秒宽限 | `token_hash` 主键，`session_id` 与 `user_id` 外键级联删除，`request_id`，`rotated_at`、`grace_until` 与轮换前后的访问令牌、刷新令牌摘要；重放不带匹配 `request_id` 或超出宽限时撤销该账号全部会话并记录安全事件 |

同轮新增的索引是 `session(refresh_expires)`、`session(user_id, created_at DESC)` 与 `auth_code(expires_at)`。字段与索引以 `schema.sql` 为准，本节只用于说明用途，不复制建表语句。

2026-11-20 增加 `user_identity`，一个账号的联系方式各占一行；`auth_code` 改成按登录方式保存，`user_id` 允许为空，索引相应换成 `auth_code(expires_at)` 与 `auth_code(user_id)`：

| 表 | 用途 | 关键列与约束 |
|---|---|---|
| `user_identity` | 账号的登录方式：邮箱现在唯一在用的种类，手机号与微信的位置已经留好 | `user_id` 外键级联删除，`kind` 的 check 约束为 `email`、`phone`、`wechat`，`identifier` 是规范化之后的值，`verified_at` 为空表示还没有确认；`(kind, identifier)` 唯一，一条联系方式只能属于一个账号；`(user_id, created_at)` 支撑账号页按顺序列出 |
| `auth_code` | 按登录方式保存的验证码，确认登录方式与找回密码共用 | 主键（用途，kind，identifier），`user_id` 外键可空且删号时级联删除，只存 HMAC-SHA256；用途的 check 约束为 `verify_contact` 与 `reset_password` |

2026-11-20 的加固轮次增加 `embedding_cache_generation`：每个账号一行缓存代次，清空云端数据时加一，嵌入请求在写入事务里比较代次，清除之前发出的请求因此写不回旧向量（[ADR-0037](../docs/adr/0037-遗留写路径与公开入口的加固.md)）。

2026-11-19 增加了 `embedding_cache` 表，保存按账号隔离的嵌入向量缓存（[ADR-0030](../docs/adr/0030-服务端不建检索索引.md)）：

| 表 | 用途 | 关键列与约束 |
|---|---|---|
| `embedding_cache` | 嵌入向量缓存，消除换机、索引重建与切换模型时的重复嵌入；属于派生数据，可以从业务库与嵌入服务重建，不进入数据包与整库备份 | `user_id` 外键级联删除，`model` 是对外模型名，`text_hash` 是片段文本的 SHA-256 小写十六进制，`dim` 与 `vector`（FP16 小端序）按长度 CHECK 绑定，主键 `(user_id, model, text_hash)`；`(user_id, last_used_at)` 支撑每账号的字节上限淘汰，`model` 上的索引支撑删模型时清理 |

`embedding_cache` 的表与索引同样以 `schema.sql` 为准；它不属于业务数据，重建库之后客户端重新查缓存、补算未命中的片段即可。

`llm_route_usage` 按自然日、用途、对外模型、来源编号和来源侧模型名保存统计计数，其中估算 Token 是结算 Token 的一部分，字段中没有账号标识或请求内容。

2026-11-21 为同步序列的快照与压缩增加了三处结构（[ADR-0043](../docs/adr/0043-服务端快照登记与提交序列压缩.md)）：`sync_head` 增加 `trimmed_through`，记录已经删除到哪个序号，保留下界等于它加一；新增 `sync_snapshot` 保存账号当前的快照指针；新增 `sync_commit_seen` 保存已经接收过的提交身份，压缩删除旧提交之后仍然按它去重。同一天还为提交的一致性摘要给 `sync_commit` 增加可空列 `state_digest`（[改进方案 3.5](../docs/数据版本系统对照git的改进方案.md)）：客户端只在推送完成且本机没有待推送提交时带上，服务端原样保存、不解析，拉取时原样带回，没有带的提交这一列为空。已有实例按当前 `schema.sql` 重建库，不写迁移（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)）。

| 表 | 用途 | 关键列与约束 |
|---|---|---|
| `sync_snapshot` | 账号当前快照的指针，每账号最多一行；字节是对象存储里的 `attachments/<账号>/<sha256>` | `user_id` 主键并外键级联删除，`seq` 是快照覆盖到的服务端位置，`sha256`、`digest` 与 `created_at`；登记更新的位置时整行覆盖 |
| `sync_commit_seen` | 已经接收过的提交身份，压缩删除旧提交之后仍然按它去重 | `user_id` 外键级联删除，主键 `(user_id, request_id)`；每行几十字节，不进入 256 MiB 的序列预算 |

## 目录

```
server/
├── api/openapi.yaml            ← 接口契约，唯一真相
├── cmd/zhixin-api/             ← 入口：读配置、选存储、启动与优雅退出
├── cmd/backfill-attachments/   ← 回填附件索引的一次性命令，见[附件与备份的字节](#附件与备份的字节)
├── 运维手册.md                  ← 资源清单、授权方式与配置
├── internal/
│   ├── config/                 ← ZHIXIN_* 环境变量与发布清单文件
│   ├── httpx/                  ← problem+json、JSON 解码与大小上限、请求编号、访问日志、异常恢复、请求体落盘校验、429
│   ├── auth/                   ← 账号、argon2id 密码与不透明令牌、鉴权中间件与登录失败预算
│   ├── syncsvc/                ← 每个账号一条线性提交序列，支持快照登记与压缩
│   ├── backup/                 ← 整库备份快照
│   ├── blobs/                  ← 附件对象：按内容寻址的上传、下载与存在检查
│   ├── llmproxy/               ← 模型来源与路由、聊天与嵌入代理、嵌入向量缓存与查找、每日额度、管理接口
│   ├── admin/                  ← 管理令牌校验与后台页面（ui/ 编进可执行文件）
│   ├── secretbox/              ← 来源 key 的 AES-256-GCM 加密
│   ├── release/                ← 发布清单的读取、校验与更新检查接口
│   ├── feedback/               ← 应用内反馈：校验、限流、保存与保留期清理
│   ├── retention/              ← 留存统计：匿名活跃上报、登录活跃记录与保留期清理
│   ├── ratelimit/              ← 按地址、账号与全局键的进程内令牌桶
│   ├── objectstore/            ← 字节存储：S3 兼容、本地目录与内存三种实现
│   ├── api/                    ← 生成的路由与类型（来自 api/openapi.yaml）
│   ├── server/                 ← 装配路由与中间件，端到端测试与两台设备的同步走查
│   ├── testutil/               ← 各包处理器测试共用的进程内客户端与 problem 解码
│   ├── store/                  ← 表结构（schema.sql，唯一真相）与 sqlc 查询
│   └── store/pg/               ← PostgreSQL 实现：账号、会话、提交序列、备份、附件索引、用量、反馈、活跃数据、嵌入向量缓存
└── Dockerfile
```

每个业务包自己定义存储接口并带一份内存实现，`server.Stores` 把它们收在一起，`main` 只在一处决定用内存还是 PostgreSQL、对象存储还是本地目录。业务包之间只通过 `auth.MustPrincipal` 取得当前账号，不互相引用存储；鉴权由 `auth.Middleware` 在路由层统一安装，令牌无效返回 401，读取令牌时存储故障走统一的 500 problem，两者都带 `request_id`。删除账号时 `server.DeleteAccountData` 把各存储的清理合成一次操作，任何一步失败都保留账号，以便重试。每个业务包都带处理器测试，共用 `internal/testutil` 的进程内客户端；`server_test.go` 只留装配、中间件顺序、鉴权、限流与 404 这类横切用例。

## 约定

- 路径带 `/v1` 前缀，请求与响应用 JSON。错误一律是 `application/problem+json`，`code` 取 [契约](api/openapi.yaml) 里的 `ProblemCode` 枚举，客户端按 `code` 分支，`detail` 只给开发者看，不能写入学习内容、SQL、令牌或路径。
- 响应统一带 `X-Content-Type-Options: nosniff` 与 `Cache-Control: no-store`：接口响应里可能出现账号信息与学习数据，禁止浏览器猜测内容类型，也禁止中间层缓存。
- JSON 请求体拒绝未知字段与多余内容，超过上限返回 413。读取请求体时，两次读到数据之间最多等待 `ZHIXIN_BODY_IDLE_TIMEOUT`（默认 60 秒），超时中断本次请求；读完、请求体关闭或出错时清除这个时限，不影响之后的 SSE 响应。
- 中间件顺序固定为 request_id、访问日志、安全响应头、异常恢复、鉴权、上传限流、业务；401 与 429 都带 `request_id` 并进访问日志。上传限流在鉴权之后，按账号计数，备份与附件两类请求共用一个桶。
- 鉴权默认要求 Bearer：中间件按路由模式 `r.Pattern` 判断，只有契约里标了 `security: []` 的操作公开，即存活与就绪检查、注册、登录、刷新令牌、找回密码与重设密码、发布清单、反馈与匿名活跃上报，其余一律要求访问令牌。公开操作表集中在一处（`internal/routepolicy`），内容与契约的 `security: []` 对齐；增删接口时要改契约，并在同一个 push 里同步这张表。令牌无效返回 401，读取令牌时存储故障走统一的 500 problem，两者都带 `request_id`。
- 来源地址只信配置的反向代理网段：`ZHIXIN_TRUSTED_PROXIES` 写逗号分隔的 IP 或 CIDR，只有直接对端落在其中时才取 `X-Forwarded-For` 的最后一项作为客户端地址，前面的项由客户端自己写，不可信；没有配置时只看直接对端，客户端自己写这个头也换不到另一个限流桶。IPv6 地址按 /64 归并成同一个桶，因为一台机器可以用同一个 /64 内的不同地址绕过按地址的限流。
- 登录失败按规范化的登录方式计预算，默认每秒补 0.017 个令牌、最多攒 10 个，超出时短暂返回 429，登录与删号的密码确认共用一个口径；argon2id 密码哈希同时占用的内存受 `ZHIXIN_ARGON2_MEMORY_BUDGET_MIB` 约束，并发哈希数由预算除以单次约 19 MiB 得出，超出时排队而不是继续申请内存。
- 每个账号最多保留 `ZHIXIN_MAX_SESSIONS_PER_USER` 个会话，新登录超过上限时删最旧的，过期会话每天清理一次。刷新令牌轮换之后，旧刷新令牌只在固定的 60 秒宽限内、且客户端带同一个 `request_id` 重试时才被接受；其他重放按盗用处理，撤销这个账号的全部会话并记录安全事件，因此客户端每次刷新都要带 `request_id`。
- 删除账号要重新提交当前密码：`DELETE /v1/me` 的请求体是 `{"password":"..."}`，密码错误返回 401 `invalid_credentials`，应用只提示密码错误并保留当前登录。清除云端数据统一走 `DELETE /v1/cloud`，清除期间这个账号的写入返回 409 `conflict`，见[同步协议](#同步协议)。
- 模型代理在账号没有任何一种已验证登录方式时返回 403 `contact_unverified`；每个账号同时最多 `ZHIXIN_LLM_CONCURRENT_PER_USER` 个托管请求，整个实例的在途字节受 `ZHIXIN_LLM_MAX_INSTANCE_BYTES` 约束，非流式响应不超过 `ZHIXIN_LLM_MAX_RESPONSE_BYTES`，流式响应有空闲与总时限；额度在请求开始时预留、按实际用量结算，账号用途额度与实例当日总预算任一用完都返回 429 `quota_exceeded`。
- 附件的单个上限、账号总量上限与 `storage_full` 见[附件与备份的字节](#附件与备份的字节)；发布清单的地址必须是 https、`sha256` 与 `signature` 均必填，见[更新检查](#更新检查)。
- `/admin/v1/` 下的管理操作按匹配到的路由校验独立的管理令牌，配置方式见[管理后台](#管理后台)。
- 契约绑定的参数由生成的路由解析后传入处理器，缺 header 或参数不是整数由统一的错误处理函数返回 problem+json，处理器不再自己解析一遍；存储查询的参数统一用 `sqlc.arg`，日期与时间解析失败直接报错。
- 访问日志只记录路由模式、状态码、字节数与耗时，不记录请求体、查询串与请求头；模型代理不保存请求与回答正文，只记 token 数。
- 服务端接受的客户端数据版本是 `server.ClientSchemaVersion`，必须与 [01](../docs/01-ER数据模型.md) 开头的 schema 编号一致。客户端升 schema 时同一个 push 里改这个常量；其他版本的提交与备份一律拒绝，与 [ADR-0002](../docs/adr/0002-本地数据不做迁移.md) 相同。
- 1.0.0 之前接口与表结构都可以直接改，不写迁移，客户端与服务端一起升级（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)）。

## 同步协议

服务端为每个账号保存一条线性的提交序列，不合并、不解析内容。客户端推送时带上自己所知的 `base_seq`，等于服务端 head 才追加，否则返回 409 和最新 head；客户端先拉取 `after=<本机已同步位置>` 的提交，在本机按现有的净变化应用为新的本地提交（撤销与数据版本页因此照常可用），再重新推送。每条提交带客户端的 `request_id`，这个字段携带的是提交的 uid：它标识一条提交，不按命令参数生成，也不复用，服务端仍按它永久去重，已经收到过的提交会被跳过，所以丢失响应之后原样重试是安全的，同参数的不同提交不会互相顶掉（[ADR-0040](../docs/adr/0040-数据版本的提交身份与同步变基.md)）。每条提交还带客户端的 schema 版本，服务端只接受当前版本 30（`server.ClientSchemaVersion`），不符时返回 400 `invalid_request`，`extra.schema_version` 给出服务端接受的版本；`GET /v1/sync/head` 同样返回这个版本，客户端对照本机版本决定是否继续同步。同一字段在两台设备上并发修改时，后到达服务端的覆盖先到达的，被覆盖的值留在提交历史里；这条规则在 2026-11-18 的协议走查中确认可用，真机走查待内测阶段补做。

客户端第一次同步时先拉取这个账号已有的全部提交并在本机应用，拉取时记下被远端提交触及过的表与主键，只把云端还没有的行作为一份或几份基线提交上传，全新设备不上传任何内容，之后只推送新提交，取舍见 [ADR-0023](../docs/adr/0023-首次同步上传基线.md) 与[改进方案 3.6](../docs/数据版本系统对照git的改进方案.md)。基线提交的来源记为 `system`、动作写“首次同步基线”，服务端与其他提交一样只做校验和保存，不区分基线；本机提交编号不进入提交内容；同步位置存在客户端库里的 `revision_cursor`（`sync.pushed` 与 `sync.server_head`），写入“账号编号 + 实例来源”的哈希作为 `scope`，随整库备份一起恢复。退出登录与删除账号只把推送位置改成不阻塞、位置与 `scope` 保留，重新登录同一身份时从原位置继续增量同步；清除云端数据时两个位置与恢复标记一并删除，下一次同步按首次基线重建。整库恢复之后本机补记一条差异提交，下一轮同步跳过旧位置、只把恢复前后的差异推上去，两个位置收敛到当前服务端位置与本机 `HEAD`，恢复之前的改动不会再从旧位置拉回来。提交里引用的附件在推送之后按哈希上传、拉取之后按哈希下载，服务端按内容寻址核对，业务行只保存哈希。同步推送与备份、附件上传共用按账号的写入速率，单条提交至多 2 MiB，单次请求至多 16 MiB，每账号提交序列预算为 256 MiB。超出请求大小返回 413 `payload_too_large`；超出序列预算时先按下一段的规则压缩，压缩之后仍然超出才返回 413 `storage_full`。客户端按字节和条数分批推送。PostgreSQL 拉取按 `ZHIXIN_SYNC_PULL_MAX_BYTES` 选出连续页，再读取正文，客户端以下一页起点之前的最后一个序号继续读取。如果游标的下一条旧提交单独就超出页上限，接口返回 413，由已备份本机数据的用户清除云端序列后重新上传基线。

每条提交还可以带一个可选的 `state_digest`（[改进方案 3.5](../docs/数据版本系统对照git的改进方案.md)）：客户端在推送完成、本机没有待推送提交的那一刻，把当前整库摘要附在最后一条提交上，摘要是全部业务行按“表名、主键、规范化整行”做 SHA-256 再求和的多重集哈希，64 位小写十六进制。服务端原样保存、不解析也不校验，拉取时原样带回；没有带摘要的提交在响应里不出现这个字段。其他设备拉到最新一条带摘要的提交、并且自己也没有待推送提交时比较本机摘要，不一致就在账号页显示“本机与云端不一致”并给出两个修复入口，同时写一条诊断记录；字段对旧客户端可省略，两者仍能互相收发提交。

服务端的提交序列可以压缩，压缩的基准是一份客户端上传的快照（[ADR-0043](../docs/adr/0043-服务端快照登记与提交序列压缩.md)）。已经同步到某个位置、没有待推送提交的设备，把当前投影按检查点格式压缩之后走 `PUT /v1/blobs/{sha256}` 当作附件上传，再用 `PUT /v1/sync/snapshot` 登记“序列 N 的快照是附件哈希 X、整库摘要是 D”。登记时 `seq` 必须在 1 与当前 head 之间，两个哈希都是 64 位小写十六进制，`sha256` 必须是这个账号已经上传、大小不超过单个附件上限的附件；位置比已经登记的快照小时返回 409，`extra.snapshot_seq` 给出当前位置，相同位置按幂等重试接受并刷新指针。服务端只保存最新一份快照指针，被替换下来的旧指针不再引用，附件字节的处理见本节最后一段与[表结构](#表结构)。

登记快照时服务端顺带压缩一次：快照位置及之前、服务端收到时间早于 `ZHIXIN_SYNC_COMPACT_KEEP`（默认 168 小时）的提交删除，保留下界 `earliest_seq` 跟着推进，它表示第一条仍然可以拉取的序号，没有删除过提交时为 1。`GET /v1/sync/head`、`GET /v1/sync/snapshot` 与 `GET /v1/sync/commits` 的响应都带 `earliest_seq` 与当前快照指针 `snapshot`（`seq`、`sha256`、`digest`、`created_at`），客户端据此判断要不要先下载快照。推送让账号超过 256 MiB 预算时，服务端先做一次压缩：有快照就删掉快照位置之前的全部提交，这一次不按保留期过滤，重新计算之后仍然超出才返回 413 `storage_full`；没有快照的账号维持原来的行为。

客户端的拉取位置落在已经删除的区间时，接口返回明确的错误：`after + 1 < earliest_seq` 说明客户端要的下一条提交已经删除，`GET /v1/sync/commits` 返回 410，`code` 是 `history_compacted`，`extra` 给出 `after`、`earliest_seq`、`head` 与 `snapshot_seq`、`snapshot_sha256`、`snapshot_digest`。客户端按 `snapshot_sha256` 下载快照附件、导入本机、把同步位置改成 `snapshot_seq`，再把未推送的本机提交在快照之上重放，服务端的序列与快照本身不变。`after` 恰好等于 `earliest_seq - 1` 时照常增量返回；`after` 为 0 而保留下界大于 1 的首次同步同样返回 410，新设备应当先读 `head` 或拉取响应里的 `snapshot` 再下载。快照附件与业务附件共用账号附件总量配额，被替换下来的旧快照不删除，随清空云端数据一起消失；客户端侧的首次同步下载快照、重新克隆判定与空闲时登记快照由后续任务接，在它接入之前没有设备登记快照，服务端不会删除任何提交。

清空一个账号的云端数据走 `DELETE /v1/cloud`：依次删除全部备份、提交序列、附件索引与对象存储里遗留的字节，可重复调用，失败之后重试从剩下的部分继续，返回 204。清除期间这个账号的写入请求返回 409 `conflict`，账号、会话与本机数据保留；下一次同步重新上传基线。旧的 `DELETE /v1/sync/commits` 与 `DELETE /v1/backups` 仍然分别可用，只清空提交序列或备份，客户端设置页的“清除云端数据”改用 `DELETE /v1/cloud`。删除账号本身走 `DELETE /v1/me`，需要重新提交密码，删除之后账号、会话与云端数据一并消失。

两台设备的走查在 2026-11-18 按这套协议完成了一遍，用例是 [sync_walkthrough_test.go](internal/server/sync_walkthrough_test.go)，用同一个账号的两次登录模拟两台设备：设备 A 以 `base_seq=0` 上传基线；设备 B 拉取 `after=0`、应用之后推自己的编辑；两台设备交替拉取与推送；两台设备基于同一个 head 修改同一行时，先到的成功、后到的得到 409 与最新 head，后到的设备拉取之后在本机应用为新的提交再推；丢失响应之后用同一个 `request_id` 原样重推，head 与历史都不变；设备 A 上传附件之后设备 B 按哈希检查并取回；`DELETE /v1/sync/commits` 之后两台设备都从 0 重新上传基线。走查确认了本节写的规则：服务端只保证序列线性、不合并字段，同一字段并发修改时后到达的覆盖先到达的，被覆盖的值留在提交历史里，可以从数据版本页找回；真机上的两台设备走查仍待内测阶段补做。

## 附件与备份的字节

整库备份是客户端导出的 zip 原样保存，服务端只核对 `X-Content-SHA256` 与大小，不打开内容。附件走 `/v1/blobs/{sha256}`，路径里的 `sha256` 就是内容的哈希：`PUT` 把请求体写到临时文件并计算哈希，与路径一致才保存，`HEAD` 在同步前判断哪些附件已经上传过，`GET` 取回原始字节。两者都按账号隔离，键分别是 `backups/<账号>/<id>.zip` 与 `attachments/<账号>/<sha256>`，删除账号时按前缀清理；附件在同一个账号里按内容去重，不同账号之间不共享对象，因此 `HEAD` 也不会泄露别的账号有没有传过同样的内容。

设置了 `ZHIXIN_S3_ENDPOINT` 时用 S3 兼容存储，没设时写到 `ZHIXIN_BLOB_DIR`，不设数据库时用内存实现。上传的请求体先落到系统临时目录再入库，单份备份与附件的默认上限分别为 256 MiB 和 32 MiB，两个上传入口在读取请求体之前按单次上限预留临时空间，单个服务进程合计最多预留 1 GiB，用尽时返回 429。启用 PostgreSQL 的实例要求至少一种登录方式已经确认之后才接受同步、备份和附件写入，没有任何已验证方式时返回 403 `contact_unverified`。预签名直传的取舍见 [ADR-0016](../docs/adr/0016-对象存储与附件接口.md)，本期仍由服务端转发字节。

附件另有账号总量配额。每写入一个新对象之前，服务端按 `attachment` 表核对这个账号已用的字节数加上本次大小是否超过 `ZHIXIN_MAX_ACCOUNT_ATTACHMENT_BYTES`（默认 2 GiB），超过时返回 413 `storage_full`，`extra` 里带 `used_bytes` 与 `limit_bytes`，客户端提示用户清理附件或换一个账号；同一账号重复上传相同内容命中同一个对象与同一行索引，不重复计入总量。配额与用量读的是 `attachment` 索引，历史上只按对象前缀写入过字节、没有索引行的实例需要先回填：在 `server/` 目录下设置 `ZHIXIN_DATABASE_URL` 与对象存储变量之后执行 `go run ./cmd/backfill-attachments`，命令按 `attachments/<账号>/` 前缀列出对象、核对大小并补写索引行，可重复执行，已有的行不会重复插入。回填完成之前配额只按索引里的字节计算，账面数字偏小，不影响上传与下载本身。

备份的元数据与字节分两步写：上传先写对象再写行，删除与保留裁剪先删行再删对象，中断时只会留下没有元数据的对象，不会出现列表里有、下载失败的备份。删对象失败或请求被取消时，待删的 id 已经从库里消失，重试拿不到它们，所以服务按 `ZHIXIN_BACKUP_RECONCILE_INTERVAL`（默认 24 小时）对账一次：列出 `backups/` 下的对象，把库里查不到对应行、且写于一小时之前的对象删掉，一小时是给正在上传的备份留的窗口。

## 登录方式验证与找回密码

账号与登录方式分开放：`app_user` 只保存密码，邮箱这类联系方式在 `user_identity` 各占一行，取舍与代价见 [ADR-0038](../docs/adr/0038-账号与登录方式分开.md)。`kind` 的 check 约束已经写好 `email`、`phone`、`wechat` 三种，代码现在只写 `email`，注册与登录遇到识别出的手机号或微信按 `invalid_request` 拒绝。

注册与登录的请求体用 `identifier` 表示登录方式的值，服务端按值的形状识别种类并规范化：含 `@` 的按邮箱、转小写之后按 RFC 5322 的简单地址校验，符合可选加号加 6 至 20 位数字的按手机号，其余是无效输入。同一条联系方式已经登记时注册返回 409 `identifier_taken`。

注册之后的账号默认没有任何已验证的登录方式，`GET /v1/me` 返回 `{user_id, created_at, identities: [{id, kind, identifier, verified}]}`，其中 `verified` 全是 `false`。注册接口是公开的，除按来源地址限流外还有实例级上限（`ZHIXIN_REGISTER_GLOBAL_RATE` 与 `ZHIXIN_REGISTER_GLOBAL_BURST`），换地址也不能把未验证的账号刷满库；注册超过 `ZHIXIN_UNVERIFIED_KEEP_DAYS`（默认 7 天）仍没有任何一种已验证登录方式的账号由每日清理删除，登录方式、会话与验证码一并清掉，这个邮箱之后可以重新注册。

`POST /v1/me/identities/{id}/verification` 给指定的登录方式发一条六位数字验证码，`POST /v1/me/identities/{id}/verification/confirm` 用它把这条登录方式标为已确认；`id` 取自 `GET /v1/me`，只认当前账号名下的登录方式，别人的编号返回 404。已经确认过的再次请求直接返回 204，不重复发信。

`POST /v1/auth/password/forgot` 向账号登记的登录方式发送重设验证码，尚未确认的联系方式也可找回账号。`POST /v1/auth/password/reset` 在同一事务中消费验证码、确认收到验证码的那种登录方式、更新密码并撤销全部旧会话。发信按登录方式分发：现在只有邮箱走 SMTP，没有对应发送方的 kind 返回 501 `not_implemented`，发送通道没有配置时返回 503。两种验证码共用按 `kind:identifier` 的令牌桶，每 24 小时补充 4 枚，最多积存 4 枚。

验证码默认十分钟过期，同一种登录方式同一用途一分钟内只能发一次，输错超过五次就作废；库里只保存 HMAC-SHA256，密钥来自 `ZHIXIN_CODE_SECRET`，不保存六位数字本身。发信走 `ZHIXIN_SMTP_*` 配置，没有配置时这两个接口返回 503，登录、备份、同步与模型代理不受影响；`ZHIXIN_MAIL_LOG=1` 只用于本机联调，会把邮件正文写进日志，生产不能打开。验证码接口按登录方式、来源地址与联系方式分别限流，参数见下表的 `ZHIXIN_CODE_*`。

## 模型代理

客户端在设置里选择“知新服务”时，接口风格固定为 Chat Completions，地址填 `<服务地址>/v1/llm`，用访问令牌代替 key，其余请求构造与 SSE 解析沿用现有代码。服务端按请求里的 `model` 查路由表，核对这个账号当天这一类模型的用量是否低于额度，然后把 `model` 换成路由选中的来源侧模型名、换上这个来源的 key 转发，流式响应按事件边界逐块刷新，可转交的提供方错误由客户端读取。路由表只来自管理后台配置的来源与模型（`llm_provider`、`llm_model`、`llm_route` 三张表），没有环境变量来源（[ADR-0035](../docs/adr/0035-模型来源只保留后台配置.md)）；没有配置任何模型时聊天与嵌入接口返回 503。

一个对外模型可以有多条路由，请求按优先级从小到大尝试，同一优先级内按权重随机排列，最多尝试 `ZHIXIN_LLM_MAX_ATTEMPTS` 条。连接失败、响应头超时、408、429、5xx、401、403，以及转发前发现的无效响应，会尝试下一条路由，400、404、422 会结束尝试。一个来源连续失败三次后冷却 30 秒，此后每次失败将冷却时间翻倍，最长 5 分钟，冷却中的来源排在其他可用来源之后。客户端收到统一的 `upstream_failed` 错误正文，来源拒绝服务端 key 时返回 502。

聊天只允许一个候选，输出 token 上限为 8192，省略时使用 1024，每次尝试按请求字节与输出上限预留，然后按上游用量结算。流式聊天由服务端要求返回用量，已收到的用量用于结算，缺少用量时保留预留值。嵌入按输入字节预留与估算，发生错误或换路由时也会结算已发出的批次。额度默认值只是占位，实际数字待内测用量出来之后再定。

嵌入走 `POST /v1/llm/embeddings`，请求与响应是 OpenAI 的格式，`input` 只接受字符串或字符串数组，单次最多 `ZHIXIN_LLM_EMBEDDING_MAX_INPUTS` 条，客户端在语义索引页选“知新服务”时，`RemoteEmbeddingClient` 每次请求前取 `<服务地址>/v1/llm` 与当前访问令牌，模型从列表里 `kind` 为 `embedding` 的项中选。路由的 `max_batch` 大于 0 时，服务端把一次请求拆成每批不超过这个数的几批，同时最多发出四批，再按原顺序合并、`index` 从 0 连续编号；一批失败时整次请求换下一个来源重做，同一次请求的向量因此总是来自同一个来源。模型配置了维度时逐条核对向量长度，维度不符按来源故障处理；客户端请求的 `dimensions` 与配置不一致时返回 400。`GET /v1/llm/models` 的每一项带 `kind`（`chat` 或 `embedding`），嵌入模型配置了维度时带 `dimensions`。

嵌入向量另有按账号隔离的缓存，目的是消除换机、索引重建与模型在 A、B 之间切换时的重复嵌入与费用（[ADR-0030](../docs/adr/0030-服务端不建检索索引.md) 决定第 2、3 条）。客户端在自动同步开启、且这次是索引刷新时，给 `POST /v1/llm/embeddings` 带 `X-Zhixin-Embedding-Cache: 1`，服务端在嵌入成功之后按每条输入的 SHA-256 写进 `embedding_cache`，重复写入不覆盖已有的行；检索查询的嵌入不带这个头，未登录、同步关闭与自填 key 直连的用户因此不会留下派生数据。索引刷新先调 `POST /v1/llm/embeddings/lookup`，请求体是 `model` 与 `hashes`（UTF-8 字节的 SHA-256 小写十六进制，单次最多 `ZHIXIN_LLM_EMBEDDING_MAX_INPUTS` 条）；命中返回小端序 FP16 的 base64 向量与 `dimensions`，全部未命中时 `vectors` 为空数组、不是错误，查找不消耗额度、不写 `llm_usage`。缓存随 `DELETE /v1/cloud` 与删除账号一起删除，清除期间带缓存头的嵌入照常返回但不写缓存；清除时缓存代次加一，清除之前发出、清除之后才落库的嵌入请求会因为代次对不上而放弃写入，清除成功的承诺不会因为在途请求而失效。每账号上限由 `ZHIXIN_LLM_EMBEDDING_CACHE_BYTES` 控制，写入之后按 `last_used_at` 删除最久未用的行。同名模型必须保持同一个向量空间：更换部署要换对外模型名，管理后台删除模型或改变维度时会先删掉这个模型的缓存行，再保存或删除，旧名字再次出现时不会命中上一个向量空间的向量。

账号没有任何一种已验证登录方式时，聊天与嵌入请求均返回 403 `contact_unverified`，这个检查默认启用，开发联调时可通过 `ZHIXIN_LLM_REQUIRE_VERIFIED_CONTACT=0` 关闭。每个账号同时最多 `ZHIXIN_LLM_CONCURRENT_PER_USER` 个托管请求，超出的请求在读取请求体之前返回 429。整个实例同时在途的请求还共用一份 `ZHIXIN_LLM_MAX_INSTANCE_BYTES` 的字节预算：请求体按声明长度的两倍（长度未知时按请求体上限）、非流式响应与嵌入请求按各自的上限在读进内存之前预留，占不到时同样回 429，实例内存因此不随账号数量上涨。非流式响应超过 `ZHIXIN_LLM_MAX_RESPONSE_BYTES` 时按无效响应处理，流式响应的空闲时限与总时限分别由 `ZHIXIN_LLM_STREAM_IDLE_TIMEOUT` 与 `ZHIXIN_LLM_STREAM_TOTAL_TIMEOUT` 决定，响应开始转发后，超时会中断当前来源并结束响应。账号的用途额度与实例当日总预算 `ZHIXIN_LLM_INSTANCE_DAILY_TOKENS` 任一用完都返回 429 `quota_exceeded`；实例预算读的是 `llm_instance_usage` 里按自然日记的账本，删号与清空云端数据都不减少它，提供方已经计费的部分因此不会重新变成可用额度。

聊天与嵌入各有一份每日额度，默认分别取 `ZHIXIN_LLM_DAILY_TOKENS` 与 `ZHIXIN_LLM_EMBEDDING_DAILY_TOKENS`，用量按账号、自然日与种类分别记在 `llm_usage`，实例当天的合计另记一份在 `llm_instance_usage`，两份在同一个事务里更新，删号只清账号那一份。嵌入的提供方没有返回 `usage` 时按输入字数估算。需要单独调整某个账号时在 `llm_quota` 表里写一行，两列分别对应聊天与嵌入，为空的一列用默认值；下一次请求就按新数字判定，不用重启服务，删掉这一行回到默认值，删号时覆盖行随外键级联删除。`GET /v1/llm/quota` 同时返回两类的用量与额度，429 的 `extra.kind` 表示请求用途，响应同时给出实例总用量与预算。额度调整是运营动作，下面的语句写在[运维手册](运维手册.md#5-常用操作)里：

```sql
-- 调高或新建一个账号的额度；只调一类时另一列写 NULL
INSERT INTO llm_quota (user_id, daily_tokens, embedding_daily_tokens, note)
VALUES ('<账号 id>', 500000, 5000000, '内测高频用户')
ON CONFLICT (user_id) DO UPDATE
SET daily_tokens = EXCLUDED.daily_tokens,
    embedding_daily_tokens = EXCLUDED.embedding_daily_tokens,
    note = EXCLUDED.note, updated_at = now();

-- 回到默认值
DELETE FROM llm_quota WHERE user_id = '<账号 id>';
```

## 管理后台

设置 `ZHIXIN_ADMIN_TOKEN`（至少 32 个字符，可以用 `openssl rand -base64 32` 生成）之后，浏览器打开 `<服务地址>/admin/`，输入这个令牌即可管理模型来源与路由；没有设置时整个 `/admin` 返回 404。页面与脚本编进可执行文件，令牌只保存在浏览器标签页的 `sessionStorage` 里。页面上能做的事都对应 `/admin/v1/` 下的接口，契约写在 `openapi.yaml` 的 `admin` 标签下，用 `Authorization: Bearer <管理令牌>` 调用：

| 接口 | 用途 |
|---|---|
| `GET /admin/v1/providers` | 列出来源、key 末四位与健康状态（连续失败次数、最近错误、冷却到何时） |
| `POST /admin/v1/providers` | 新建来源，编号放在请求体里；编号已存在时返回 409，不覆盖原来源 |
| `PUT /admin/v1/providers/{id}` | 修改已有来源；编号不存在时返回 404。`api_key` 省略时保留原值，空字符串表示清除 |
| `DELETE /admin/v1/providers/{id}` | 删除来源；还有路由指向它时返回 409，`extra.models` 列出这些模型 |
| `POST /admin/v1/providers/{id}/test` | 用来源自己的 key 请求一次 `/models`，返回可用的模型名，编辑路由时可以直接选 |
| `GET /admin/v1/models` | 列出模型的可调用状态与每条路由的状态，包括来源停用、密钥解密失败和冷却 |
| `POST /admin/v1/models` | 新建模型，名称放在请求体里；名称已存在时返回 409，不覆盖原模型的路由 |
| `PUT /admin/v1/models/{name}` | 修改已有模型，路由整体替换；名称不存在时返回 404 |
| `DELETE /admin/v1/models/{name}` | 删除模型，路由随之删除 |
| `POST /admin/v1/models/{name}/test` | 发出最小请求并报告来源、耗时与嵌入维度，同时传入 `provider_id` 与 `upstream_model` 时只探测指定路由 |
| `GET /admin/v1/usage?days=7` | 返回按日分用途的用量、各路由区间总量与有记录日期的用量，`days` 允许 1 至 30，默认 7 |

来源的 key 用 `ZHIXIN_SECRET_KEY`（32 字节的 base64，`openssl rand -base64 32`）加密入库，附加数据是来源编号与完整地址，后台修改地址的任一部分时都必须重新填写 key。生产后台的来源必须使用公网 HTTPS，连接前解析域名并核对实际连接的地址。打开后台并使用数据库时这个密钥必须配置，否则启动失败；内存存储时缺省用一把随进程消失的随机密钥。更换密钥或从旧地址绑定规则升级后，已保存的 key 显示为 `key_error`，需要在后台重新填写。来源与模型只从这三张表读取，管理后台是唯一的配置入口：新建实例或重建库之后，要先在后台新建来源、再新建模型并配置路由，聊天与嵌入接口才有可用的路由，否则一律返回 503；换 key 也在后台修改，改 `<服务地址>/admin/` 里的来源即可，不需要重启。

“对外模型与路由”页可以在模型名、备注、来源与来源侧模型名里搜索，按用途筛选，并只显示需要处理的模型：模型停用、没有可用路由，或者有冷却、密钥异常、来源停用、来源缺失的路由。每条路由可以直接停用或启用，模型也可以不打开弹窗就整体停用；这两种改动按模型整体保存，与弹窗里保存调用同一个接口。路由按优先级分组显示，同一组里的权重换算成占比，来源的连续失败次数与冷却时间显示在对应路由旁边。点“复制”把这个模型的路由填进新增表单，填一个新的名称即可得到一套相同的路由。新增来源或模型时，编号或名称已经存在会被拒绝并提示去编辑，原有配置不会被覆盖；修改接口只更新已有条目，目标不存在时返回 404。

保存之后路由立即生效；服务另外每 `ZHIXIN_MODEL_RELOAD_INTERVAL` 从数据库重新读一次，直接修改数据库也会生效。令牌校验失败按来源地址限流（`ZHIXIN_ADMIN_RATE`、`ZHIXIN_ADMIN_BURST`），超限期间这个地址的管理请求全部返回 429。后台没有操作审计，令牌等同于管理员本人，生产上应在 nginx 里把 `/admin` 限制在管理员的地址，或者只经 SSH 隧道访问，做法见[运维手册](运维手册.md#3-配置)。

嵌入模型的几条路由必须是同一个模型的不同部署，例如两家服务商提供的 `BAAI/bge-m3`，服务端只能核对维度，向量空间是否一致由管理员保证。取舍与代价见 [ADR-0029](../docs/adr/0029-模型来源路由与嵌入代理.md)。

在“对外模型与路由”页，“测试模型”按正常的候选次序尝试路由，每条路由旁的“探测”只调用所选来源侧模型，即使该来源正在冷却也可以探测，已停用的模型、路由或来源则不会发出请求。两种测试都会更新当前进程的来源健康状态，探测用量由来源侧计量，知新的账号额度和路由用量不计入探测。

“用量统计”页按 `ZHIXIN_TIMEZONE` 显示今天、最近 7 天或最近 30 天的托管用量，管理员可以按用途、对外模型、来源和来源侧模型筛选，切换每日 Token、路由尝试次数或未成功尝试次数，并选择日期查看当天明细。从路由旁的“用量”进入看板时会直接应用该条路由的筛选条件。每条路由尝试在结束时汇总到 `llm_route_usage`，切换路由时逐条记数，嵌入拆批仍算同一次尝试，后台探测、缓存查找和请求发出前的拒绝均排除在统计范围之外。Token 包含已经结算的估算值，页面单独标出估算部分，提供方费用以其账单为准。统计从启用后开始，原有的账号额度表缺少模型与来源信息，因此无法补录历史路由用量。取舍见 [ADR-0034](../docs/adr/0034-模型路由用量汇总.md)，已有数据库的建表步骤见[运维手册](运维手册.md#48-自动部署与回滚)。

## 更新检查

`GET /v1/app/releases` 公开返回发布清单，登录之前也能调用。清单是一份 JSON 文件，路径由 `ZHIXIN_RELEASE_FILE` 给出，启动时读入并校验：字段是否齐全、地址是否为绝对的 https 地址、`sha256` 是否必填且为 64 位小写十六进制、`signature` 是否是必填的 64 字节 Ed25519 签名 base64、平台是否重复。路径为空时接口返回空数组。配置的文件不存在或内容不合法时，服务拒绝启动。发版流程使用 `RELEASE_SIGNING_KEY_BASE64` 中的 Ed25519 私钥对安装包 SHA-256 的小写十六进制字符串签名，应用使用随包提供的公钥验签。应用的更新检查与下载入口见 [02 第 3.16 节](../docs/02-产品与交互.md#316-账号与云同步)。

```json
{
  "releases": [
    {
      "platform": "android",
      "version": "0.2.0",
      "build": 2,
      "published_at": "2026-12-21",
      "url": "https://zhixin.chensiyuan.work/downloads/zhixin-0.2.0.apk",
      "sha256": "…64 位小写十六进制…",
      "signature": "…64 字节 Ed25519 签名的 base64…",
      "size": 48200000,
      "min_version": "0.1.0",
      "notes": "登录、云端备份与同步"
    }
  ]
}
```

服务端只原样给出这些字段，不比较客户端版本，也不判断是否必须更新；客户端按平台取一项，自己比较 `version` 与 `build`，低于 `min_version` 时提示必须更新。发布新版本时把安装包放到清单里的地址，用发版流程给出的 sha256 与 signature 改清单，再重启服务；清单、签名与安装包要在同一步更新，客户端核对清单里的哈希格式、下载后的内容与签名，对不上时不提示更新；安装包由系统浏览器下载与系统安装器安装，因此三者不一致时用户只会停留在旧版本。清单格式随后端一起演进，开发阶段不承诺兼容（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)），取舍见 [ADR-0025](../docs/adr/0025-应用内更新检查与反馈的接口口径.md)。

## 应用内反馈

`POST /v1/feedback` 公开接收一条反馈，登录与否都能提交，服务端不读 `Authorization`，也不把反馈绑定到账号。正文 `content` 必填，去掉两端空白后 1 至 4000 字；`contact` 可选，必须是普通邮箱地址，用于回复；`app_version`、`platform` 与 `diagnostics` 可选，上限分别是 64 字、32 字与 64 KiB。诊断摘要由客户端先在本地说明会提交哪些内容，再截取用户看过的片段，不自动上传整份诊断记录。提交按来源地址限流，参数见下表的 `ZHIXIN_FEEDBACK_*`；来源地址通过之后再消耗实例额度，参数见 `ZHIXIN_FEEDBACK_GLOBAL_*`。实例最多保留 10,000 条反馈，满时返回 429，按保留期清理后可继续接收。

反馈写入 PostgreSQL 的 `feedback` 表，内存存储时只在进程里保留，重启即丢。接口只写不读：管理员按下面的语句查看和清理，不另开列表接口。保留期由 `ZHIXIN_FEEDBACK_KEEP_DAYS` 控制，默认 365 天，`feedback.PruneLoop` 在启动时清一次、之后每天清一次，平时不需要手工删除；要立刻清理或调整保留期时才执行下面的语句。

```sql
SELECT id, created_at, app_version, platform, contact, content, diagnostics
FROM feedback ORDER BY created_at DESC LIMIT 50;

DELETE FROM feedback WHERE created_at < now() - interval '365 days';
```

删除账号不影响已经提交的反馈，因为反馈本来就不属于账号；删除云端数据也不涉及这张表。正文与诊断摘要不写日志，与访问日志同一口径。

## 留存统计

S4 与 S5 要求统计一周与四周留存（[03 第 4 节](../docs/03-团队分工与协作.md#4-成功标准)），采集口径见 [ADR-0019](../docs/adr/0019-留存统计用匿名上报.md)，[00 第 7 章](../docs/00-产品定义.md#7-边界)写明不含学习内容。服务端分两路记录，都不解析学习内容：

- 登录账号的活跃：鉴权中间件在每次令牌校验成功之后调用 `retention.Service.RecordUserActive`，按 `ZHIXIN_TIMEZONE` 的自然日记一行到 `user_active`，同一个账号同一天只在第一次写库。不需要客户端额外上报，也不需要客户端带日期。
- 未登录设备的活跃：`POST /v1/telemetry/active` 公开接收 `install_id`、可选的 `app_version` 与 `platform`。服务端自己决定日期，不使用客户端时钟；安装标识校验格式之后算 HMAC-SHA256，库里只存哈希与日期，同一个标识同一天重复上报是幂等的。按来源地址限流，参数见配置表的 `ZHIXIN_TELEMETRY_*`，并受整个实例的全局写入上限 `ZHIXIN_TELEMETRY_GLOBAL_*` 约束；密钥来自 `ZHIXIN_TELEMETRY_SECRET`，为空时每次启动随机生成，重启后同一个安装会被当成新的，因此生产必须固定。

```json
{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "app_version": "0.2.0-dev+3", "platform": "android"}
```

匿名活跃按 180 天滚动删除：进程启动时清一次，之后每天清一次，`install_active` 里早于 180 天的行由 `retention.PruneLoop` 删掉；登录账号的活跃行数很小，随删号级联删除，不单独清理。两张表都不保存原始安装标识、IP、设备编号或账号之外的标识，管理员直接查库得到留存数字，不另开读取接口：

```sql
-- 每日活跃：匿名安装数与登录账号数
SELECT day, count(*) AS active_installs FROM install_active GROUP BY day ORDER BY day;
SELECT day, count(*) AS active_users FROM user_active GROUP BY day ORDER BY day;

-- 一周留存：按首次出现的日子分组，7 天内再次活跃的比例；四周把 7 改成 28
WITH first_seen AS (
  SELECT install_hash, min(day) AS first_day FROM install_active GROUP BY install_hash
)
SELECT f.first_day,
       count(*) AS installs,
       count(*) FILTER (
         WHERE EXISTS (
           SELECT 1 FROM install_active a
           WHERE a.install_hash = f.install_hash
             AND a.day > f.first_day
             AND a.day <= f.first_day + 7
         )
       ) AS returned_7d
FROM first_seen f
GROUP BY f.first_day
ORDER BY f.first_day;
```

客户端的上报任务、安装标识的生成与保存、首次使用说明与设置页开关按 ADR-0019 已经接入：启动之后的空闲任务里尝试一次，每天最多成功一次，失败静默重试一次并写本机诊断；首次启动用一次说明讲清采集内容与用途，设置页“使用统计”可以随时关闭，关闭后不再上报。登录账号的活跃不需要客户端参与，两路数据因此都会进表；统计只用于按周与按月看留存，不统计功能使用，也不与其他数据关联。

## 配置

全部配置来自环境变量，唯一的例外是发布清单的内容从 `ZHIXIN_RELEASE_FILE` 指向的文件读取；仓库里不保存任何地址、口令与 key。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ZHIXIN_ADDR` | `:8080` | 监听地址 |
| `ZHIXIN_DATABASE_URL` | 空 | 空表示内存存储；设置之后用 PostgreSQL |
| `ZHIXIN_BLOB_DIR` | `data/blobs` | 没配置对象存储时，备份与附件字节的落盘目录；只在设置了数据库时读取 |
| `ZHIXIN_S3_ENDPOINT` | 空 | S3 兼容存储的 `host[:port]`，不带协议；设置之后备份与附件都走对象存储 |
| `ZHIXIN_S3_BUCKET` | `zhixin` | 对象存储的 bucket，启动时不在就报错 |
| `ZHIXIN_S3_ACCESS_KEY` | 空 | 对象存储的 access key，设置了 endpoint 时必填 |
| `ZHIXIN_S3_SECRET_KEY` | 空 | 对象存储的 secret key，设置了 endpoint 时必填 |
| `ZHIXIN_S3_REGION` | 空 | 对象存储的 region，MinIO 一般留空 |
| `ZHIXIN_S3_USE_SSL` | `0` | 设为 `1` 时用 https 访问对象存储 |
| `ZHIXIN_APPLY_SCHEMA` | `0` | 设为 `1` 时启动按 `schema.sql` 建表，用于空库 |
| `ZHIXIN_TIMEZONE` | `Asia/Shanghai` | 额度按这个时区的自然日计 |
| `ZHIXIN_ACCESS_TTL` | `1h` | 访问令牌有效期 |
| `ZHIXIN_REFRESH_TTL` | `720h` | 刷新令牌有效期，必须长于访问令牌 |
| `ZHIXIN_AUTH_RATE` | `0.2` | 注册与登录按来源地址的令牌桶补充速率（个/秒），设 `0` 关闭 |
| `ZHIXIN_AUTH_BURST` | `10` | 注册与登录的桶容量，两者共用一个桶 |
| `ZHIXIN_LOGIN_FAIL_RATE` | `0.017` | 登录失败按规范化登录方式的补充速率（个/秒），约每分钟一次；注册、登录与删号共用这个预算 |
| `ZHIXIN_LOGIN_FAIL_BURST` | `10` | 登录失败的桶容量，连续失败十次之后开始返回 429 |
| `ZHIXIN_ARGON2_MEMORY_BUDGET_MIB` | `256` | 密码哈希同时占用的内存预算（MiB），并发哈希数由它除以单次约 19 MiB 得出 |
| `ZHIXIN_MAX_SESSIONS_PER_USER` | `20` | 每个账号保留的会话数上限，新登录超过时删最旧的 |
| `ZHIXIN_RATE_LIMIT_KEYS` | `100000` | 每个进程内限流器保留的最大桶数，超出时清理空闲桶或淘汰最久未用的键 |
| `ZHIXIN_REFRESH_RATE` | `1` | 刷新令牌按账号与来源地址的补充速率，设 `0` 关闭 |
| `ZHIXIN_REFRESH_BURST` | `30` | 刷新令牌的桶容量 |
| `ZHIXIN_UPLOAD_RATE` | `0.5` | 备份与附件上传按账号的补充速率，设 `0` 关闭 |
| `ZHIXIN_UPLOAD_BURST` | `5` | 备份与附件上传的桶容量，两类请求共用一个桶 |
| `ZHIXIN_SMTP_ADDR` | 空 | 发信服务器，`host:port`；为空时登录方式验证与找回密码返回 503 |
| `ZHIXIN_SMTP_FROM` | 空 | 发件人地址；设置了 `ZHIXIN_SMTP_ADDR` 时必填 |
| `ZHIXIN_SMTP_USERNAME` | 空 | SMTP 用户名，留空表示不鉴权 |
| `ZHIXIN_SMTP_PASSWORD` | 空 | SMTP 口令；有用户名时必填 |
| `ZHIXIN_SMTP_TLS` | `starttls` | `starttls`、`implicit`（465 端口）或 `none`（仅本机联调） |
| `ZHIXIN_MAIL_LOG` | `0` | 设为 `1` 时把邮件写进日志；只用于本机联调，配置了数据库时启动会拒绝 |
| `ZHIXIN_CODE_SECRET` | 空 | 验证码 HMAC 的密钥；为空时每次启动随机生成，重启后旧验证码失效，配置了数据库时必填 |
| `ZHIXIN_CODE_TTL` | `10m` | 验证码有效期 |
| `ZHIXIN_CODE_COOLDOWN` | `60s` | 同一账号两次发送验证码的最小间隔 |
| `ZHIXIN_CODE_RATE` | `0.02` | 发送验证码与重设密码按账号或地址的补充速率（个/秒），设 `0` 关闭 |
| `ZHIXIN_CODE_BURST` | `1` | 验证码与重设密码的桶容量 |
| `ZHIXIN_FEEDBACK_RATE` | `0.02` | 应用内反馈按来源地址的补充速率（个/秒），设 `0` 关闭 |
| `ZHIXIN_FEEDBACK_BURST` | `3` | 应用内反馈的桶容量 |
| `ZHIXIN_FEEDBACK_GLOBAL_RATE` | `2` | 整个实例的反馈写入补充速率（个/秒），与按地址的桶同时生效 |
| `ZHIXIN_FEEDBACK_GLOBAL_BURST` | `30` | 全局反馈桶容量 |
| `ZHIXIN_FEEDBACK_KEEP_DAYS` | `365` | 反馈保留天数，更早的行由每日清理删除 |
| `ZHIXIN_TELEMETRY_SECRET` | 空 | 匿名安装标识的 HMAC 密钥；为空时每次启动随机生成，重启后留存数字偏高，配置了数据库时必填 |
| `ZHIXIN_TELEMETRY_RATE` | `0.2` | 匿名活跃上报按来源地址的补充速率（个/秒），设 `0` 关闭 |
| `ZHIXIN_TELEMETRY_BURST` | `20` | 匿名活跃上报的桶容量；同一出口地址后面可能有多台设备，容量留得比反馈大 |
| `ZHIXIN_TELEMETRY_GLOBAL_RATE` | `5` | 整个实例的匿名上报写入补充速率（个/秒） |
| `ZHIXIN_TELEMETRY_GLOBAL_BURST` | `100` | 全局匿名上报桶容量 |
| `ZHIXIN_TRUSTED_PROXIES` | 空 | 逗号分隔的反向代理 IP 或 CIDR；只有直接对端落在其中时才取 `X-Forwarded-For` 的末项，为空表示只看直接对端，见[约定](#约定) |
| `ZHIXIN_RELEASE_FILE` | 空 | 发布清单文件路径；为空时更新检查返回空数组，见[更新检查](#更新检查) |
| `ZHIXIN_MAX_JSON_BYTES` | `1048576` | 普通 JSON 请求体上限；同步推送为它的 16 倍，最高 16 MiB |
| `ZHIXIN_BODY_IDLE_TIMEOUT` | `60s` | 读取请求体时两次读到数据之间的最长等待，超时中断本次请求 |
| `ZHIXIN_MAX_BACKUP_BYTES` | `268435456` | 单份备份上限，与客户端历史的 256 MB 容量预算一致 |
| `ZHIXIN_MAX_ATTACHMENT_BYTES` | `33554432` | 单个附件的上限，客户端上传前按它预检 |
| `ZHIXIN_MAX_ACCOUNT_ATTACHMENT_BYTES` | `2147483648` | 一个账号全部附件的总量上限，超限上传返回 413 `storage_full` |
| `ZHIXIN_SYNC_PULL_MAX_BYTES` | `4194304` | 一次拉取同步提交的累计字节上限，最大 16 MiB；下一条超过上限时返回 413 |
| `ZHIXIN_SYNC_COMPACT_KEEP` | `168h` | 快照位置之下仍然保留提交的时间窗口：登记快照时删除更早的已覆盖提交。窗口越长，落后设备越少重新克隆，序列占地也越大（[ADR-0043](../docs/adr/0043-服务端快照登记与提交序列压缩.md)） |
| `ZHIXIN_BACKUPS_KEPT` | `5` | 每个账号保留的备份份数 |
| `ZHIXIN_BACKUP_RECONCILE_INTERVAL` | `24h` | 备份对象对账的周期：列出对象存储里的备份对象，删掉库里已经没有元数据、且写于一小时前的遗留字节 |
| `ZHIXIN_REGISTER_GLOBAL_RATE` | `0.05` | 注册的实例级上限（个/秒），与按来源地址的桶同时生效，换地址也不能把未验证账号灌满库 |
| `ZHIXIN_REGISTER_GLOBAL_BURST` | `10` | 注册实例级上限的桶容量 |
| `ZHIXIN_UNVERIFIED_KEEP_DAYS` | `7` | 没有任何已验证登录方式的账号保留天数，超过之后由每日清理删除，释放联系方式与账号行 |
| `ZHIXIN_LLM_DAILY_TOKENS` | `200000` | 每个账号每日聊天 token 额度，也是 `llm_quota.daily_tokens` 为空时的默认值；公测免费，数字按内测用量调整（[04 第 5 节](../docs/04-长期路线图.md#5-决定) D4） |
| `ZHIXIN_LLM_EMBEDDING_DAILY_TOKENS` | `2000000` | 每个账号每日嵌入 token 额度，也是 `llm_quota.embedding_daily_tokens` 为空时的默认值；占位数字，待内测用量出来再定 |
| `ZHIXIN_LLM_MAX_REQUEST_BYTES` | `8388608` | 代理请求体上限，图片以 base64 内联 |
| `ZHIXIN_LLM_EMBEDDING_MAX_INPUTS` | `256` | 一次嵌入请求最多的输入条数，查找接口的 `hashes` 上限相同 |
| `ZHIXIN_LLM_EMBEDDING_CACHE_BYTES` | `1073741824` | 每个账号的嵌入向量缓存上限（字节，默认 1 GiB）；写入之后按 `last_used_at` 删除最久未用的行，磁盘与出口流量要按实际用量监控 |
| `ZHIXIN_LLM_MAX_ATTEMPTS` | `3` | 一次请求最多尝试的路由条数 |
| `ZHIXIN_LLM_HEADER_TIMEOUT` | `60s` | 流式聊天与嵌入等待来源响应头的时间，超时换下一个来源；非流式聊天不设这个期限 |
| `ZHIXIN_ADMIN_TOKEN` | 空 | 管理后台的令牌，至少 32 个字符；为空时 `/admin` 一律 404 |
| `ZHIXIN_ADMIN_RATE` | `0.05` | 管理令牌校验失败按来源地址的补充速率（个/秒），设 `0` 关闭 |
| `ZHIXIN_ADMIN_BURST` | `5` | 管理令牌校验失败的桶容量 |
| `ZHIXIN_SECRET_KEY` | 空 | 加密来源 key 的 32 字节密钥（base64）；打开后台并使用数据库时必填 |
| `ZHIXIN_MODEL_RELOAD_INTERVAL` | `30s` | 从数据库重新读取模型路由的周期 |
| `ZHIXIN_LLM_INSTANCE_DAILY_TOKENS` | `20000000` | 整个实例一天的总 token 预算，用尽之后所有托管请求都返回 429 |
| `ZHIXIN_LLM_REQUIRE_VERIFIED_CONTACT` | `1` | 设为 `1` 时没有任何已验证登录方式的账号不能使用托管额度，聊天与嵌入入口均返回 403 `contact_unverified` |
| `ZHIXIN_LLM_CONCURRENT_PER_USER` | `4` | 同一账号同时进行的托管请求上限 |
| `ZHIXIN_LLM_MAX_INSTANCE_BYTES` | `268435456` | 整个实例同时在途的托管请求可占用的内存上限（字节，默认 256 MiB）；请求体按两倍大小、非流式响应与嵌入批次按响应上限从这里预留，占不到时返回 429 |
| `ZHIXIN_LLM_MAX_RESPONSE_BYTES` | `33554432` | 非流式响应上限，超过时按 `upstream_failed` 处理 |
| `ZHIXIN_LLM_STREAM_IDLE_TIMEOUT` | `90s` | 流式响应两次收到数据之间的最长等待 |
| `ZHIXIN_LLM_STREAM_TOTAL_TIMEOUT` | `30m` | 一次流式聊天或嵌入请求的总时限 |

## 部署与凭据

第一套实例跑在一台单机 Debian 13 上，不做容器化，原因与取舍见 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md) 第 7 条。`zhixin-api` 由 systemd 拉起，只监听回环地址，前面的 nginx 终止 TLS 并反向代理到它；数据库用发行版包安装的 PostgreSQL 17；备份与附件的字节放 S3 兼容的对象存储，第一套实例用阿里云 OSS，端点、地域、bucket 与密钥都写在服务器的环境变量里，不配置对象存储时回落到 `ZHIXIN_BLOB_DIR` 指向的本机目录，只用于本地开发。域名由管理员在 DNS 里指向这台机器，证书由 certbot 申请并自动续期。需要注入的环境变量就是上面配置表里的那些，仓库里不写口令与 key；资源清单、地址、接入方式与操作步骤见[运维手册](运维手册.md)。

加固轮次之后，启动时会自检生产配置：配置了数据库时 `ZHIXIN_MAIL_LOG` 必须为 `0`，`ZHIXIN_CODE_SECRET` 与 `ZHIXIN_TELEMETRY_SECRET` 必须固定，带认证的 SMTP 连接不允许 `none`，任何一项不满足都拒绝启动；第一套实例因此需要在 `api.env` 里补上两个固定密钥。带 key 的模型上游公网地址必须是 https，这条在后台保存来源时校验，不再随启动检查。按地址的限流要分清真实用户，`ZHIXIN_TRUSTED_PROXIES` 写 `127.0.0.1/32,::1/128`（nginx 只从回环地址连进来）；服务直接对外监听时保持为空。改了 `ZHIXIN_TRUSTED_PROXIES` 或其它配置之后重启服务生效，部署前按[运维手册](运维手册.md#4-加固后的运维动作)的核对清单逐项确认。

部署已经与仓库联动：`main` 收到 `server/**` 的推送后，[deploy-server.yml](../.github/workflows/deploy-server.yml) 先跑与服务端 CI 相同的一组检查，通过之后交叉编译、上传、重启并核对 `/readyz`，失败时自动换回上一份可执行文件，也可以从 Actions 手动运行；账号、secrets、回滚与轮换步骤见[运维手册](运维手册.md#48-自动部署与回滚)，取舍见 [ADR-0032](../docs/adr/0032-main推送后自动部署服务端.md)。自动部署不处理表结构与运行配置，`schema.sql` 与 `api.env` 的变化仍在服务器上手工执行；部署工作流本身不可用时，照旧三步手工发布：在开发机上交叉编译，把可执行文件传到服务器的 `/opt/zhixin/bin/`，再执行 `systemctl restart zhixin-api`，回滚是把 `zhixin-api.prev` 换回去重新启动。发版时还要把安装包放到清单里的地址，用 Actions 发版任务在 step summary 里给出的 `sha256` 与 `signature` 更新 `ZHIXIN_RELEASE_FILE` 指向的 JSON 文件，再重启服务；地址必须是 https，漏掉这一步或清单与安装包对不上时客户端都不会提示更新。空库首次启动前把 `ZHIXIN_APPLY_SCHEMA` 设为 `1`，建表之后改回 `0`，因为 `schema.sql` 不带 `IF NOT EXISTS`，重复执行会报错。同步快照带来的三处结构（`sync_head.trimmed_through`、`sync_snapshot`、`sync_commit_seen`）同样要在现有实例上按当前 `schema.sql` 重建库；保留期 `ZHIXIN_SYNC_COMPACT_KEEP` 有默认值 168 小时，不配置也照常运行，内测期间希望落后设备少重新克隆时可以调到 720 小时并写进 `api.env`，重启后生效。日常备份是 `pg_dump`，加上对象存储里 `backups/` 与 `attachments/` 两个前缀下的字节；删号与删除备份都会按前缀清理，所以两处要一起备。

服务器只有一位管理员（[04 第 5 节](../docs/04-长期路线图.md#5-决定) D7），不设第二位。数据库口令、对象存储密钥、TLS 证书与备份介质的存放位置，以及主机失联、数据库损坏、对象存储不可用三种情况下的恢复步骤，由管理员写在仓库之外的私有目录；仓库只保留需要哪些变量与恢复的先后顺序。公测准备阶段做一次恢复演练，用备份重建一台可用实例，演练日期与结果写进结题材料。

## 本地运行与检查

需要 Go 1.27。

```bash
cd server
go run ./cmd/zhixin-api              # 内存存储，监听 :8080
curl localhost:8080/healthz
curl localhost:8080/v1/app/releases  # 没有配置发布清单时是空数组
curl -X POST localhost:8080/v1/feedback \
  -H 'Content-Type: application/json' \
  -d '{"content":"记录页按下一步没有反应","app_version":"0.2.0-dev+3","platform":"android"}'
curl -X POST localhost:8080/v1/telemetry/active \
  -H 'Content-Type: application/json' \
  -d '{"install_id":"0f8fad5b-d9cb-469f-a165-70867728950e","app_version":"0.2.0-dev+3","platform":"android"}'
```

本地要试模型代理时，先给服务一个管理令牌，再经管理接口登记来源与模型（内存存储的加密密钥随进程生成，重启后要重新登记）：

```bash
ZHIXIN_ADMIN_TOKEN=$(openssl rand -base64 32) go run ./cmd/zhixin-api
TOKEN=$ZHIXIN_ADMIN_TOKEN
curl -H "Authorization: Bearer $TOKEN" -X POST localhost:8080/admin/v1/providers \
  -H 'Content-Type: application/json' \
  -d '{"id":"deepseek","base_url":"https://api.deepseek.com/v1","api_key":"sk-..."}'
curl -H "Authorization: Bearer $TOKEN" -X POST localhost:8080/admin/v1/models \
  -H 'Content-Type: application/json' \
  -d '{"name":"deepseek-flash","kind":"chat","routes":[{"provider_id":"deepseek","upstream_model":"deepseek-chat"}]}'
curl localhost:8080/v1/llm/models
```

设置 `ZHIXIN_DATABASE_URL` 之后启动就用 PostgreSQL，备份与附件默认写到 `ZHIXIN_BLOB_DIR`。要连 MinIO 时设置 `ZHIXIN_S3_ENDPOINT`、`ZHIXIN_S3_BUCKET`、`ZHIXIN_S3_ACCESS_KEY` 与 `ZHIXIN_S3_SECRET_KEY`，bucket 要先建好，`/readyz` 会检查它是否存在。

2026 年 11 月 15 日用 PostgreSQL 17 与从 `RELEASE.2025-10-15T17-29-55Z` 构建的 MinIO 本地联调，服务端为 `9bf7474`。附件校验哈希，重复上传只保留一个对象，另一账号无法读取。约 18 MiB 的备份可上传并逐字节下载，保留两份时最旧对象会清理。删除备份和删除账号后直接列出 bucket，确认相应对象已清除。

提交前执行与 CI 相同的四条命令：

```bash
gofmt -l .        # 应当没有输出
go mod tidy -diff
go vet ./...
go test ./...
```

改了 `schema.sql` 或 `internal/store/queries/` 下的查询要先重新运行 `sqlc`，改了 `openapi.yaml` 要先重新运行 `oapi-codegen`，生成结果随源文件一起提交；CI 会重新生成并用 `git diff --exit-code` 核对，本地少了这一步时编译与测试仍可能通过，推上去却会在生成核对上失败。

端到端测试在 [server_test.go](internal/server/server_test.go)，用 `httptest` 起完整的处理链，覆盖注册登录、令牌作废、没有配置发信时的登录方式验证行为、同步的线性与幂等、备份的哈希校验与保留份数、附件的上传下载与哈希校验、账号之间的隔离、附件大小上限与账号总量配额、删除账号时清理数据、`DELETE /v1/cloud` 的清除与清除期间的 409，以及模型代理的转发、key 替换、用量记录、未验证登录方式的 403、账号并发上限、额度拒绝与按账号调整；更新检查与反馈也在这里核对公开访问、清单内容与限流，匿名活跃上报核对公开访问与幂等。两台设备的同步走查在 [sync_walkthrough_test.go](internal/server/sync_walkthrough_test.go)，按[同步协议](#同步协议)的顺序走完基线、交替推送、并发冲突、重试、附件与清空之后重新上传，`go test ./internal/server -run TestTwoDeviceSyncWalkthrough -v` 会打印每一步的结果。快照登记与压缩的用例在 [syncsvc](internal/syncsvc/snapshot_test.go) 的存储、服务与处理器三层，PostgreSQL 侧的指针、保留期压缩与去重表在 [store/pg](internal/store/pg/store_test.go)。验证码与找回密码的流程在 [codes_test.go](internal/auth/codes_test.go) 用进程内发信实现覆盖，[feedback](internal/feedback/handler_test.go) 包覆盖反馈的字段边界、限流、全局写入上限、保留期清理与存储故障，[release](internal/release/release_test.go) 包覆盖清单的读取、强制 https 与 sha256、签名格式与不合法输入，[retention](internal/retention/service_test.go) 包覆盖安装标识校验、哈希与密钥、按天去重、全局写入上限与保留期清理；PostgreSQL 存储用例覆盖验证码、登录方式与已验证时间、`feedback` 表、两张活跃表、额度覆盖行与附件索引的读写。[objectstore](internal/objectstore/objectstore_test.go) 与 [blobs](internal/blobs/blobs_test.go) 另有单元测试，覆盖本地目录与内存两种实现的对象读写、前缀清理与长度校验；S3 另按本节的本地联调记录验证。P2 加固的用例跟着改动分布在各自包里：缓存代次在 [llmproxy](internal/llmproxy/embedding_cache_test.go) 与 [cloudpurge](internal/cloudpurge/cloudpurge_test.go)，遗留对象对账在 [backup](internal/backup/reconcile_test.go) 与 [objectstore](internal/objectstore/objectstore_test.go)，刷新事务与未验证账号保留期在 [auth](internal/auth/hardening_test.go) 与 [store/pg](internal/store/pg/refresh_atomic_test.go)；接入层的注册上限与启动清理在 [p2_hardening_test.go](internal/server/p2_hardening_test.go)。

模型路由测试覆盖来源优先级、权重与冷却、失败后换来源、嵌入拆批及合并和按用途计量。PostgreSQL 存储用例另覆盖来源、模型与路由的配置读写。

本机没有设置 `ZHIXIN_TEST_DATABASE_URL` 时，`internal/store/pg` 的用例会整体跳过，`go test ./...` 因此在没有数据库的机器上也能通过；改动 `schema.sql`、查询或这张用例自己的删表清单时，要在有 PostgreSQL 的环境（CI 或服务器上的临时库）再跑一次 `go test ./internal/store/pg`，否则生成的表结构对不上只会在 CI 或线上暴露。2026-11-20 新增 `user_identity` 时就漏改过删表清单，本地全绿、CI 失败。
