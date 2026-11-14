# 知新 · API 后端

> 本目录是知新的自建 API 服务，第一期负责账号与登录、整库备份与增量同步、模型请求代理。为什么要有服务端、它不负责什么，见 [ADR-0008](../docs/adr/0008-取消单机边界引入账号同步与模型代理.md)；为什么用 Go、怎样分层，见 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md)。接口以 [api/openapi.yaml](api/openapi.yaml) 为准，本文只说明工程结构、约定与本地运行。

## 当前状态

骨架可以编译、启动并通过测试，全部存储目前是内存实现，进程退出后数据丢失，所以只能用于本地开发与联调。账号、提交序列的推送与拉取、整库备份的上传下载与保留份数、模型代理的转发与额度都已经按契约实现；附件对象的 `/v1/blobs` 在契约里，处理函数返回 501。设置 `ZHIXIN_DATABASE_URL` 时服务拒绝启动，因为 PostgreSQL 与对象存储的实现还没有写，这样做是为了避免以为数据已经落库而实际留在内存里。

接下来的顺序是：PostgreSQL 存储（按 [schema.sql](internal/store/schema.sql)），对象存储与 `/v1/blobs`，部署到与自建 Sentry 相同的服务器，然后接入客户端的登录、备份与“知新服务”模型来源。增量同步要等客户端业务表主键改为全局唯一之后再接，见 [01 第 8 节](../docs/01-ER数据模型.md#8-待验证与待定)。

PostgreSQL 存取用 `pgx` 加 `sqlc` 生成，契约用 `oapi-codegen` 生成并挂到标准库路由上，登录与刷新令牌用 `golang.org/x/time/rate` 限流，依赖清单与理由见 [ADR-0015](../docs/adr/0015-服务端引入代码生成与限流依赖.md)。生成代码与客户端一样提交入库，提交前重新生成并核对没有差异。

## 目录

```
server/
├── api/openapi.yaml            ← 接口契约，唯一真相
├── cmd/zhixin-api/             ← 入口：读配置、选存储、启动与优雅退出
├── internal/
│   ├── config/                 ← ZHIXIN_* 环境变量
│   ├── httpx/                  ← problem+json、JSON 解码与大小上限、请求编号、访问日志、异常恢复
│   ├── auth/                   ← 账号、argon2id 密码、不透明令牌、Require 中间件
│   ├── syncsvc/                ← 每个账号一条线性提交序列
│   ├── backup/                 ← 整库备份快照
│   ├── llmproxy/               ← Chat Completions 代理与每日额度
│   ├── server/                 ← 装配路由与中间件，端到端测试
│   └── store/schema.sql        ← PostgreSQL 表结构草案
└── Dockerfile
```

每个业务包自己定义存储接口并带一份内存实现，`server.Stores` 把它们收在一起，`main` 只在一处决定用内存还是 PostgreSQL。业务包之间只通过 `auth.PrincipalFrom` 取得当前账号，不互相引用存储；删除账号时，各业务包通过 `auth.Service.OnAccountDelete` 登记的清理函数先删自己的数据，任何一步失败都保留账号，以便重试。

## 约定

- 路径带 `/v1` 前缀，请求与响应用 JSON。错误一律是 `application/problem+json`，`code` 取 [problem.go](internal/httpx/problem.go) 里列出的分类，客户端按 `code` 分支，`detail` 只给开发者看，不能写入学习内容、SQL、令牌或路径。
- JSON 请求体拒绝未知字段与多余内容，超过上限返回 413。
- 访问日志只记录路由模式、状态码、字节数与耗时，不记录请求体、查询串与请求头；模型代理不保存请求与回答正文，只记 token 数。
- 服务端接受的客户端数据版本是 `server.ClientSchemaVersion`，必须与 [01](../docs/01-ER数据模型.md) 开头的 schema 编号一致。客户端升 schema 时同一个 push 里改这个常量；其他版本的提交与备份一律拒绝，与 [ADR-0002](../docs/adr/0002-本地数据不做迁移.md) 相同。
- 1.0.0 之前接口与表结构都可以直接改，不写迁移，客户端与服务端一起升级（[ADR-0001](../docs/adr/0001-开发阶段不向下兼容.md)）。

## 同步协议

服务端为每个账号保存一条线性的提交序列，不合并、不解析内容。客户端推送时带上自己所知的 `base_seq`，等于服务端 head 才追加，否则返回 409 和最新 head；客户端先拉取 `after=<本机已同步位置>` 的提交，在本机按现有的净变化应用为新的本地提交（撤销与数据版本页因此照常可用），再重新推送。每条提交带客户端的 `request_id`，已经收到过的会被跳过，所以丢失响应之后原样重试是安全的。同一字段在两台设备上并发修改时，后到达服务端的覆盖先到达的，被覆盖的值留在提交历史里；这条规则是否够用，在两台设备走查之后再定。

## 模型代理

客户端在设置里选择“知新服务”时，接口风格固定为 Chat Completions，地址填 `<服务地址>/v1/llm`，用访问令牌代替 key，其余请求构造与 SSE 解析沿用现有代码。服务端核对模型名是否在 `ZHIXIN_LLM_MODELS` 中、当日用量是否低于 `ZHIXIN_LLM_DAILY_TOKENS`，然后换上服务端持有的 key 转发，流式响应按事件边界逐块刷新，提供方的错误状态与响应体原样返回。用量从响应的 `usage.total_tokens` 读取，所以流式请求要带 `stream_options.include_usage`，客户端已经这样做。额度默认值只是占位，实际数字待定。

## 配置

全部配置来自环境变量，仓库里不保存任何地址、口令与 key。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ZHIXIN_ADDR` | `:8080` | 监听地址 |
| `ZHIXIN_DATABASE_URL` | 空 | 空表示内存存储；PostgreSQL 实现完成前设置会拒绝启动 |
| `ZHIXIN_TIMEZONE` | `Asia/Shanghai` | 额度按这个时区的自然日计 |
| `ZHIXIN_ACCESS_TTL` | `1h` | 访问令牌有效期 |
| `ZHIXIN_REFRESH_TTL` | `720h` | 刷新令牌有效期，必须长于访问令牌 |
| `ZHIXIN_MAX_JSON_BYTES` | `1048576` | 普通 JSON 请求体上限；同步推送为它的 16 倍 |
| `ZHIXIN_MAX_BACKUP_BYTES` | `268435456` | 单份备份上限，与客户端历史的 256 MB 容量预算一致 |
| `ZHIXIN_BACKUPS_KEPT` | `5` | 每个账号保留的备份份数 |
| `ZHIXIN_LLM_BASE_URL` | `https://api.deepseek.com/v1` | 提供方的 Chat Completions 基础地址 |
| `ZHIXIN_LLM_API_KEY` | 空 | 提供方 key；为空时代理返回 503 |
| `ZHIXIN_LLM_MODELS` | `deepseek-flash` | 允许的模型名，逗号分隔 |
| `ZHIXIN_LLM_DAILY_TOKENS` | `200000` | 每个账号每日 token 额度，待定 |
| `ZHIXIN_LLM_MAX_REQUEST_BYTES` | `8388608` | 代理请求体上限，图片以 base64 内联 |

## 本地运行与检查

需要 Go 1.27。

```bash
cd server
go run ./cmd/zhixin-api              # 内存存储，监听 :8080
curl localhost:8080/healthz
```

提交前执行与 CI 相同的三条命令：

```bash
gofmt -l .        # 应当没有输出
go vet ./...
go test ./...
```

端到端测试在 [server_test.go](internal/server/server_test.go)，用 `httptest` 起完整的处理链，覆盖注册登录、令牌作废、同步的线性与幂等、备份的哈希校验与保留份数、删除账号时清理数据，以及模型代理的转发、key 替换、用量记录与额度拒绝。
