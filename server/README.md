# 知新 · API 后端

> 本目录是知新的自建 API 服务，第一期负责账号与登录、整库备份与增量同步、模型请求代理。为什么要有服务端、它不负责什么，见 [ADR-0008](../docs/adr/0008-取消单机边界引入账号同步与模型代理.md)；为什么用 Go、怎样分层，见 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md)。接口以 [api/openapi.yaml](api/openapi.yaml) 为准，本文只说明工程结构、约定与本地运行。

## 当前状态

路由由 `api/openapi.yaml` 经 `oapi-codegen` 生成到 `internal/api/`，`internal/server/routes.go` 只把生成的路由转发给各业务包的处理器；契约改了而转发没跟上时编译失败。账号、邮箱验证与找回密码、提交序列的推送与拉取、整库备份的上传下载与保留份数、附件的上传下载与存在检查、模型代理的转发与额度都已经按契约实现。存储分两种：不设 `ZHIXIN_DATABASE_URL` 时全部在内存里，进程退出后数据丢失，只能用于本地开发与联调；设置之后账号、会话、提交序列、备份元数据与用量入库（`internal/store/pg`，查询由 `sqlc` 从 `internal/store/queries` 生成），字节放对象存储（`internal/objectstore`）：设了 `ZHIXIN_S3_ENDPOINT` 用 S3 兼容存储，没设时落到 `ZHIXIN_BLOB_DIR` 指定的本地目录，进程重启都不丢。首次在空库上启动时设 `ZHIXIN_APPLY_SCHEMA=1`，服务会按 `internal/store/schema.sql` 建表，建完可以去掉。附件按内容寻址，服务端核对 SHA-256 之后保存，单个上限见配置表的 `ZHIXIN_MAX_ATTACHMENT_BYTES`。

`schema.sql` 在 2026-11-17 增加了 `auth_code` 表与 `app_user.email_verified_at`。开发阶段不写迁移（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)），已有实例按当前 `schema.sql` 重建库；当时实例里只有联调数据。

CI 使用临时 PostgreSQL 实例执行服务端存储测试；在开发机上可以设置 `ZHIXIN_TEST_DATABASE_URL` 执行同一组用例，连接串须指向允许重建表的专用测试库。

账号保留时可以单独清空云端数据：`DELETE /v1/backups` 删除该账号的全部备份，元数据行与对象存储里的字节一并删除，`DELETE /v1/sync/commits` 清空全部提交并把服务端 head 重置为 0，两者都返回 204，账号本身不受影响。客户端据此在设置页提供“清除云端数据”，调用前应提示用户会失去云端副本，本机数据库不受影响。

第一套实例已经在一台单机 Debian 13 上跑起来，备份与附件的字节放阿里云 OSS 的 S3 兼容接口，部署方式见[部署与凭据](#部署与凭据)。客户端已经接入登录、邮箱验证、找回密码、整库备份、按提交的增量同步与“知新服务”模型来源，首次同步上传当前数据为基线的取舍见 [ADR-0023](../docs/adr/0023-首次同步上传基线.md)。接下来的顺序是两台设备的同步走查与限额调整；邮箱验证与找回密码按 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md) 第 5 条已经落地。

PostgreSQL 存取用 `pgx` 加 `sqlc` 生成，契约用 `oapi-codegen` 生成并挂到标准库路由上，登录与刷新令牌用 `golang.org/x/time/rate` 限流，对象存储用 `minio-go` 访问，依赖清单与理由见 [ADR-0015](../docs/adr/0015-服务端引入代码生成与限流依赖.md) 与 [ADR-0016](../docs/adr/0016-对象存储与附件接口.md)。生成代码与客户端一样提交入库，提交前重新生成并核对没有差异；生成命令在 `server/` 目录下执行，`api/cfg.yaml` 里的输出路径相对这个目录：

```bash
cd server
go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.2 -config api/cfg.yaml api/openapi.yaml
go run github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1 generate
```

## 目录

```
server/
├── api/openapi.yaml            ← 接口契约，唯一真相
├── cmd/zhixin-api/             ← 入口：读配置、选存储、启动与优雅退出
├── 运维手册.md                  ← 资源清单、授权方式与配置
├── internal/
│   ├── config/                 ← ZHIXIN_* 环境变量
│   ├── httpx/                  ← problem+json、JSON 解码与大小上限、请求编号、访问日志、异常恢复、请求体落盘校验
│   ├── auth/                   ← 账号、argon2id 密码与不透明令牌、鉴权中间件
│   ├── syncsvc/                ← 每个账号一条线性提交序列
│   ├── backup/                 ← 整库备份快照
│   ├── blobs/                  ← 附件对象：按内容寻址的上传、下载与存在检查
│   ├── llmproxy/               ← Chat Completions 代理与每日额度
│   ├── objectstore/            ← 字节存储：S3 兼容、本地目录与内存三种实现
│   ├── api/                    ← 生成的路由与类型（来自 api/openapi.yaml）
│   ├── server/                 ← 装配路由与中间件，端到端测试
│   ├── testutil/               ← 各包处理器测试共用的进程内客户端与 problem 解码
│   ├── store/                  ← 表结构（schema.sql，唯一真相）与 sqlc 查询
│   └── store/pg/               ← PostgreSQL 实现：账号、会话、提交序列、备份、用量
└── Dockerfile
```

每个业务包自己定义存储接口并带一份内存实现，`server.Stores` 把它们收在一起，`main` 只在一处决定用内存还是 PostgreSQL、对象存储还是本地目录。业务包之间只通过 `auth.MustPrincipal` 取得当前账号，不互相引用存储；鉴权由 `auth.Middleware` 在路由层统一安装，令牌无效返回 401，读取令牌时存储故障走统一的 500 problem，两者都带 `request_id`。删除账号时 `server.DeleteAccountData` 把各存储的清理合成一次操作，任何一步失败都保留账号，以便重试。四个业务包各自带处理器测试，共用 `internal/testutil` 的进程内客户端；`server_test.go` 只留装配、中间件顺序、鉴权、限流与 404 这类横切用例。

## 约定

- 路径带 `/v1` 前缀，请求与响应用 JSON。错误一律是 `application/problem+json`，`code` 取 [契约](api/openapi.yaml) 里的 `ProblemCode` 枚举，客户端按 `code` 分支，`detail` 只给开发者看，不能写入学习内容、SQL、令牌或路径。
- JSON 请求体拒绝未知字段与多余内容，超过上限返回 413。
- 中间件顺序固定为 request_id、访问日志、异常恢复、鉴权、上传限流、业务；401 与 429 都带 `request_id` 并进访问日志。
- 契约绑定的参数由生成的路由解析后传入处理器，缺 header 或参数不是整数由统一的错误处理函数返回 problem+json，处理器不再自己解析一遍；存储查询的参数统一用 `sqlc.arg`，日期与时间解析失败直接报错。
- 访问日志只记录路由模式、状态码、字节数与耗时，不记录请求体、查询串与请求头；模型代理不保存请求与回答正文，只记 token 数。
- 服务端接受的客户端数据版本是 `server.ClientSchemaVersion`，必须与 [01](../docs/01-ER数据模型.md) 开头的 schema 编号一致。客户端升 schema 时同一个 push 里改这个常量；其他版本的提交与备份一律拒绝，与 [ADR-0002](../docs/adr/0002-本地数据不做迁移.md) 相同。
- 1.0.0 之前接口与表结构都可以直接改，不写迁移，客户端与服务端一起升级（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)）。

## 同步协议

服务端为每个账号保存一条线性的提交序列，不合并、不解析内容。客户端推送时带上自己所知的 `base_seq`，等于服务端 head 才追加，否则返回 409 和最新 head；客户端先拉取 `after=<本机已同步位置>` 的提交，在本机按现有的净变化应用为新的本地提交（撤销与数据版本页因此照常可用），再重新推送。每条提交带客户端的 `request_id`，已经收到过的会被跳过，所以丢失响应之后原样重试是安全的。同一字段在两台设备上并发修改时，后到达服务端的覆盖先到达的，被覆盖的值留在提交历史里；这条规则是否够用，在两台设备走查之后再定。

客户端第一次同步时先拉取这个账号已有的提交并在本机应用，再把当前业务投影作为一份或几份基线提交上传，之后只推送新提交，取舍见 [ADR-0023](../docs/adr/0023-首次同步上传基线.md)。基线提交的来源记为 `system`、动作写“首次同步基线”，服务端与其他提交一样只做校验和保存，不区分基线；本机提交编号与同步游标不进入提交内容，保存在客户端应用私有目录里，恢复备份或换机之后按当前数据重新对齐。提交里引用的附件在推送之后按哈希上传、拉取之后按哈希下载，服务端按内容寻址核对，业务行只保存哈希。

清空一个账号的同步序列走 `DELETE /v1/sync/commits`，删除全部提交并把 head 重置为 0，账号与备份保留；清空备份走 `DELETE /v1/backups`，两者都返回 204，可以重复调用。客户端在设置页“清除云端数据”里同时调用这两个接口，之后下一次同步重新上传基线。

## 附件与备份的字节

整库备份是客户端导出的 zip 原样保存，服务端只核对 `X-Content-SHA256` 与大小，不打开内容。附件走 `/v1/blobs/{sha256}`，路径里的 `sha256` 就是内容的哈希：`PUT` 把请求体写到临时文件并计算哈希，与路径一致才保存，`HEAD` 在同步前判断哪些附件已经上传过，`GET` 取回原始字节。两者都按账号隔离，键分别是 `backups/<账号>/<id>.zip` 与 `attachments/<账号>/<sha256>`，删除账号时按前缀清理；附件在同一个账号里按内容去重，不同账号之间不共享对象，因此 `HEAD` 也不会泄露别的账号有没有传过同样的内容。

设置了 `ZHIXIN_S3_ENDPOINT` 时用 S3 兼容存储，没设时写到 `ZHIXIN_BLOB_DIR`，不设数据库时用内存实现。上传的请求体先落到系统临时目录再入库，备份上限 256 MB，附件的上限见配置表；并发上传时临时目录要放得下这些字节。预签名直传的取舍见 [ADR-0016](../docs/adr/0016-对象存储与附件接口.md)，本期仍由服务端转发字节。

## 邮箱验证与找回密码

注册之后的账号默认没有确认邮箱，`GET /v1/me` 的 `email_verified` 为 `false`。`POST /v1/auth/email/verify/request` 给当前账号的邮箱发一条六位数字验证码，`POST /v1/auth/email/verify/confirm` 用它把邮箱标为已确认；已确认的账号再次请求直接返回 204，不重复发信。

找回密码分两步。`POST /v1/auth/password/forgot` 只向已验证的邮箱发重设验证码，邮箱不存在或没有验证时同样返回 204，调用方无法据此判断哪些邮箱注册过；`POST /v1/auth/password/reset` 校验验证码、写入新密码并删除这个账号的全部会话，旧密码与旧令牌立即失效。

验证码默认十分钟过期，同一账号同一用途一分钟内只能发一次，输错超过五次就作废；库里只保存 HMAC-SHA256，密钥来自 `ZHIXIN_CODE_SECRET`，不保存六位数字本身。发信走 `ZHIXIN_SMTP_*` 配置，没有配置时这两个接口返回 503，登录、备份、同步与模型代理不受影响；`ZHIXIN_MAIL_LOG=1` 只用于本机联调，会把邮件正文写进日志，生产不能打开。验证码接口按账号、来源地址与邮箱分别限流，参数见下表的 `ZHIXIN_CODE_*`。

## 模型代理

客户端在设置里选择“知新服务”时，接口风格固定为 Chat Completions，地址填 `<服务地址>/v1/llm`，用访问令牌代替 key，其余请求构造与 SSE 解析沿用现有代码。服务端核对模型名是否在 `ZHIXIN_LLM_MODELS` 中、当日用量是否低于 `ZHIXIN_LLM_DAILY_TOKENS`，然后换上服务端持有的 key 转发，流式响应按事件边界逐块刷新，提供方的错误状态与响应体原样返回。用量从响应的 `usage.total_tokens` 读取，所以流式请求要带 `stream_options.include_usage`，客户端已经这样做。额度默认值只是占位，实际数字待定。

## 配置

全部配置来自环境变量，仓库里不保存任何地址、口令与 key。

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
| `ZHIXIN_REFRESH_RATE` | `1` | 刷新令牌按账号与来源地址的补充速率，设 `0` 关闭 |
| `ZHIXIN_REFRESH_BURST` | `30` | 刷新令牌的桶容量 |
| `ZHIXIN_UPLOAD_RATE` | `0.5` | 备份与附件上传按账号的补充速率，设 `0` 关闭 |
| `ZHIXIN_UPLOAD_BURST` | `5` | 备份与附件上传的桶容量，两类请求共用一个桶 |
| `ZHIXIN_SMTP_ADDR` | 空 | 发信服务器，`host:port`；为空时邮箱验证与找回密码返回 503 |
| `ZHIXIN_SMTP_FROM` | 空 | 发件人地址；设置了 `ZHIXIN_SMTP_ADDR` 时必填 |
| `ZHIXIN_SMTP_USERNAME` | 空 | SMTP 用户名，留空表示不鉴权 |
| `ZHIXIN_SMTP_PASSWORD` | 空 | SMTP 口令；有用户名时必填 |
| `ZHIXIN_SMTP_TLS` | `starttls` | `starttls`、`implicit`（465 端口）或 `none`（仅本机联调） |
| `ZHIXIN_MAIL_LOG` | `0` | 设为 `1` 时把邮件写进日志；只用于本机联调，日志里会出现验证码 |
| `ZHIXIN_CODE_SECRET` | 空 | 验证码 HMAC 的密钥；为空时每次启动随机生成，重启后旧验证码失效 |
| `ZHIXIN_CODE_TTL` | `10m` | 验证码有效期 |
| `ZHIXIN_CODE_COOLDOWN` | `60s` | 同一账号两次发送验证码的最小间隔 |
| `ZHIXIN_CODE_RATE` | `0.02` | 发送验证码与重设密码按账号或地址的补充速率（个/秒），设 `0` 关闭 |
| `ZHIXIN_CODE_BURST` | `1` | 验证码与重设密码的桶容量 |
| `ZHIXIN_MAX_JSON_BYTES` | `1048576` | 普通 JSON 请求体上限；同步推送为它的 16 倍 |
| `ZHIXIN_MAX_BACKUP_BYTES` | `268435456` | 单份备份上限，与客户端历史的 256 MB 容量预算一致 |
| `ZHIXIN_BACKUPS_KEPT` | `5` | 每个账号保留的备份份数 |
| `ZHIXIN_LLM_BASE_URL` | `https://api.deepseek.com/v1` | 提供方的 Chat Completions 基础地址 |
| `ZHIXIN_LLM_API_KEY` | 空 | 提供方 key；为空时代理返回 503 |
| `ZHIXIN_LLM_MODELS` | `deepseek-flash` | 允许的模型名，逗号分隔 |
| `ZHIXIN_LLM_DAILY_TOKENS` | `200000` | 每个账号每日 token 额度；公测免费，数字按内测用量调整（[04 第 5 节](../docs/04-长期路线图.md#5-决定) D4） |
| `ZHIXIN_LLM_MAX_REQUEST_BYTES` | `8388608` | 代理请求体上限，图片以 base64 内联 |

## 部署与凭据

第一套实例跑在一台单机 Debian 13 上，不做容器化，原因与取舍见 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md) 第 7 条。`zhixin-api` 由 systemd 拉起，只监听回环地址，前面的 nginx 终止 TLS 并反向代理到它；数据库用发行版包安装的 PostgreSQL 17；备份与附件的字节放 S3 兼容的对象存储，第一套实例用阿里云 OSS，端点、地域、bucket 与密钥都写在服务器的环境变量里，不配置对象存储时回落到 `ZHIXIN_BLOB_DIR` 指向的本机目录，只用于本地开发。域名由管理员在 DNS 里指向这台机器，证书由 certbot 申请并自动续期。需要注入的环境变量就是上面配置表里的那些，仓库里不写口令与 key；资源清单、地址、接入方式与操作步骤见[运维手册](运维手册.md)。

部署与升级只有三步：在开发机上交叉编译 `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o zhixin-api ./cmd/zhixin-api`，把可执行文件传到服务器的 `/opt/zhixin/bin/`，再执行 `systemctl restart zhixin-api`。回滚是把上一个可执行文件换回去重新启动。空库首次启动前把 `ZHIXIN_APPLY_SCHEMA` 设为 `1`，建表之后改回 `0`，因为 `schema.sql` 不带 `IF NOT EXISTS`，重复执行会报错。日常备份是 `pg_dump`，加上对象存储里 `backups/` 与 `attachments/` 两个前缀下的字节；删号与删除备份都会按前缀清理，所以两处要一起备。

服务器只有一位管理员（[04 第 5 节](../docs/04-长期路线图.md#5-决定) D7），不设第二位。数据库口令、对象存储密钥、TLS 证书与备份介质的存放位置，以及主机失联、数据库损坏、对象存储不可用三种情况下的恢复步骤，由管理员写在仓库之外的私有目录；仓库只保留需要哪些变量与恢复的先后顺序。公测准备阶段做一次恢复演练，用备份重建一台可用实例，演练日期与结果写进结题材料。

## 本地运行与检查

需要 Go 1.27。

```bash
cd server
go run ./cmd/zhixin-api              # 内存存储，监听 :8080
curl localhost:8080/healthz
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

端到端测试在 [server_test.go](internal/server/server_test.go)，用 `httptest` 起完整的处理链，覆盖注册登录、令牌作废、没有配置发信时的邮箱验证行为、同步的线性与幂等、备份的哈希校验与保留份数、附件的上传下载与哈希校验、账号之间的隔离、附件大小上限、删除账号时清理数据，以及模型代理的转发、key 替换、用量记录与额度拒绝。验证码与找回密码的流程在 [codes_test.go](internal/auth/codes_test.go) 用进程内发信实现覆盖，PostgreSQL 存储用例覆盖验证码与已验证时间的读写。[objectstore](internal/objectstore/objectstore_test.go) 与 [blobs](internal/blobs/blobs_test.go) 另有单元测试，覆盖本地目录与内存两种实现的对象读写、前缀清理与长度校验；S3 另按本节的本地联调记录验证。
