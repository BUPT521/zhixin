# ADR-0009 API 后端采用 Go 与分层框架

## 状态

提议。职责范围来自 [ADR-0008](0008-取消单机边界引入账号同步与模型代理.md)；`server/` 已有可编译的骨架，部署与客户端接入完成后改为已采纳。第 1 条里“第三方依赖只在标准库没有对应能力时加入”的清单由 [ADR-0015](0015-服务端引入代码生成与限流依赖.md) 更新，PostgreSQL 驱动、代码生成工具与限流库的取舍见那一条。

## 日期

2026-11-14

## 背景

ADR-0008 决定增加一个自建 API 服务，第一期承担账号与登录、整库备份与增量同步、模型请求代理。服务部署在项目组自己的服务器上，与自建 Sentry 共用运维人力；团队四人每周合计 32 小时，没有专职的后端或运维成员，因此服务要容易部署、依赖少、出问题时容易定位。客户端是 Flutter，模型接入已经实现了 Chat Completions、Responses 与 Anthropic Messages 三种请求格式与 SSE 流式解析（见 [应用工程说明](../../app/README.md#模型)）。

## 决定

1. 服务端用 Go 1.27 编写，代码放在仓库根目录的 `server/`，构建为单个可执行文件 `zhixin-api`。HTTP 层只用标准库 `net/http` 的方法路由、`log/slog` 与 `httptest`，不引入 Web 框架；第三方依赖只在标准库没有对应能力时加入，目前只有 `golang.org/x/crypto` 的 argon2id。
2. 工程按职责分包：`cmd/zhixin-api` 只负责读取配置与启动；`internal/config` 从环境变量读取配置；`internal/httpx` 放请求编号、访问日志、异常恢复、请求体上限与统一错误格式；`internal/auth`、`internal/backup`、`internal/syncsvc`、`internal/llmproxy` 各自包含处理函数、业务服务与存储接口；`internal/server` 只负责装配路由与中间件。业务包之间不互相引用存储实现，测试用内存实现替换。
3. 接口契约以 [`server/api/openapi.yaml`](../../server/api/openapi.yaml) 为准。路径统一带 `/v1` 前缀，请求与响应用 JSON，错误用 RFC 9457 的 `application/problem+json`，`type` 字段取程序定义的错误分类，客户端按分类给出提示，不解析错误文字。写入接口接受 `Idempotency-Key` 请求头，同步推送直接复用客户端提交的 `request_id`，重试不重复写入。
4. 数据存放分两处。账号、会话、提交序列与模型用量放 PostgreSQL；附件对象与整库备份按 SHA-256 放 S3 兼容的对象存储，自建时用 MinIO。骨架阶段只有内存实现，PostgreSQL 与对象存储的实现按存储接口补上。服务端数据库同样适用 [ADR-0001](0001-开发阶段不向下兼容.md)，1.0.0 之前表结构直接按 `schema.sql` 重建，不写迁移。
5. 账号用邮箱与密码登录，密码以 argon2id 加盐保存。登录返回不透明的访问令牌与刷新令牌，访问令牌一小时过期，刷新令牌三十天过期并在每次刷新时轮换；服务端只保存令牌的 SHA-256，退出登录或删除账号时立即作废。邮箱验证与找回密码列为待定，内测前确定是否需要。
6. 模型代理兼容 OpenAI Chat Completions：服务端在 `/v1/llm/chat/completions` 接收请求，校验模型名是否在允许列表内，检查当日额度，替换为服务端持有的提供方 key 之后原样转发，流式响应逐块刷新给客户端。客户端因此只需把接口地址设为 `<服务地址>/v1/llm`、把访问令牌当作 key，现有的请求构造与 SSE 解析不必改。Responses 与 Anthropic Messages 的代理留到有需要时再加。
7. 服务以容器镜像部署，前面放一个负责 TLS 的反向代理；健康检查为 `/healthz`（进程存活）与 `/readyz`（依赖可用）。CI 增加一个任务，在 `server/` 下执行 `gofmt`、`go vet` 与 `go test`。

## 代价与边界

- 团队要同时维护 Dart 与 Go 两种语言，客户端与服务端的数据结构不能共享代码，只能靠 OpenAPI 契约与双方的测试保持一致。契约改动必须与两端代码放进同一个 push。
- 不用 Web 框架意味着参数绑定、校验与路由分组要自己写，代码会比用框架多一些；换来的是依赖少、升级时只跟随 Go 版本。
- 不透明令牌每次请求都要查一次会话，比自校验的 JWT 多一次存储访问；在 100 人的规模下可以接受，好处是令牌可以立即作废。
- 模型代理只覆盖 Chat Completions 一种格式，选择“知新服务”时接口风格固定为 Chat Completions。

## 替代方案

- 用 Dart（`shelf` 或 `dart_frog`）写服务端，与客户端共用模型代码。没有采纳的原因是 Dart 的服务端生态与部署工具较少，SQLite 之外的数据库驱动与对象存储客户端成熟度不如 Go，并且 Go 编译出的单个可执行文件更容易部署，因此选择 Go。
- 用 Gin、Echo 或 chi。没有采纳的原因是 Go 1.22 之后标准库路由已经支持方法与路径参数，第一期的接口数量用不到框架的其余功能。
- 用 JWT 作访问令牌。没有采纳的原因是 JWT 难以在退出或删除账号时立即作废，需要另建黑名单，最终仍要查存储。
- 用 gRPC。没有采纳的原因是模型代理与 SSE 流式响应天然是 HTTP，Flutter 侧也已经有 HTTP 客户端，引入 gRPC 只会多一套生成代码。

## 影响

- [服务端工程说明](../../server/README.md)、[API 契约](../../server/api/openapi.yaml)与[数据库结构草案](../../server/internal/store/schema.sql)
- [CI 配置](../../.github/workflows/ci.yml)增加服务端检查，[提交约定第 7 节](../../CONTRIBUTING.md)增加服务端的提交前检查
- [README](../../README.md) 的技术栈表增加服务端一行
