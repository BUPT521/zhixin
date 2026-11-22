# ADR-0052 客户端改用 OpenAI 现行请求格式

## 状态

已采纳。2026-11-22 决定，客户端与服务端同日完成。本条补充 [ADR-0050](0050-客户端统一为知新服务.md) 的协议口径：客户端只剩知新服务之后，对话从 Chat Completions 改为 Responses，嵌入按现行的 `/embeddings` 参数组装。服务端的来源路由、额度与嵌入缓存机制不变，见 [ADR-0029](0029-模型来源路由与嵌入代理.md) 与 [ADR-0049](0049-嵌入统一走百炼与查询向量也走云端.md)。

## 日期

2026-11-22

## 背景

[ADR-0050](0050-客户端统一为知新服务.md) 删掉自填 Key 直连之后，客户端只连接知新服务的模型代理，协议层不再需要在几种线格式之间切换：请求体与增量解析都只有一种。协议文件于是留下三类只在某种线格式下成立的写法。第一类是 `LlmWire`、`ChatWire`、`LlmDecoder`、`ChatDecoder` 四个抽象，各只有一个实现，读代码要先跳过一层才知道请求长什么样。第二类是 Responses 遗留的 `reasoningItems`：字段沿到消息、回复与增量三层，每层都要算进上下文预算、去重与续接判断，但当前没有任何线格式会填充它。第三类是只为兼容其他提供方写的分支，例如 `max_tokens` 与 `max_completion_tokens` 二选一、两种 `input_tokens` 用量字段名（见 [ADR-0029](0029-模型来源路由与嵌入代理.md)）。

服务端代理在这一阶段固定转发一种格式，客户端跟着定的格式写完之后，上面三类写法都不再有读者。同时，OpenAI 现行的对话接口是 Responses，工具调用以 `function_call` 与 `function_call_output` 两种条目进出，与 Chat Completions 的 `tool_calls` 与 `tool` 角色消息并列，理解一套再不懂另一套反而增加联调成本。嵌入接口本身没有换名字，现行的通用形状仍是 `POST /embeddings`，`input` 为字符串或数组，响应为 `data[]` 按 `index` 排序。

## 决定

1. 对话固定走 Responses：`POST <服务地址>/v1/llm/responses`，鉴权仍是 `Authorization: Bearer <访问令牌>` 加 `Content-Type: application/json`。请求用 `model`、`instructions`、`input`、`tools`、`tool_choice`、`max_output_tokens`、`stream` 与 `store: false`。系统提示只发 `instructions`，不放进 `input`。

2. `input` 是按顺序排列的条目数组，角色只有 `user` 与 `assistant`。用户消息带图片时，`content` 为 `input_text` 与 `input_image` 两种块，图片用 `data:` 地址发送；没有图片时 `content` 写成字符串。助手消息的 `content` 为 `output_text` 块，模型发起的工具调用写成 `function_call` 条目（`call_id`、`name`、`arguments`），客户端执行之后把结果写成 `function_call_output` 条目（`call_id`、`output`），两种条目跟在发起调用的助手消息之后。

3. 工具声明用扁平形状 `{type: "function", name, description, parameters}`，`tool_choice` 取 `auto`、`none` 或 `{type: "function", name}`。工具参数按代码调用发送：`parameters` 只声明一个 `input` 数组，每一项是 `{type: "input_text", text, zod}`，`text` 是参数的 JSON 文本，`zod` 记下参数的 JSON Schema，客户端执行工具前把文本读回对象并照 `zod` 校验。`max_output_tokens` 取代 `max_tokens`，不再按模型名追加 `thinking` 一类的私有字段：思考与否属于服务端在 `llm_route` 上的来源配置，客户端不猜测提供方。

4. 流式响应按 Responses 的事件名读取：正文取自 `response.output_text.delta` 的 `delta`，工具参数取自 `response.function_call_arguments.delta` 的 `delta` 并按 `output_index` 累积，`response.output_item.done` 给出的完整 `arguments` 覆盖先前的分片，结束由 `response.completed` 判定；`response.incomplete` 按截断处理，`response.failed` 与流内 `error` 事件按服务端错误处理。整段响应从 `output` 数组里读 `output_text` 与 `function_call` 两种条目，用量取 `usage.input_tokens` 与 `usage.output_tokens`。服务端忽略 `stream` 直接返回整段 JSON 时，客户端按整段响应读出同样的增量。

5. 嵌入请求保持 `POST /v1/llm/embeddings`，参数按现行接口组装：`model` 与 `input` 必填，`encoding_format` 显式写 `float`，索引刷新需要服务端保存向量时继续用请求头 `X-Zhixin-Embedding-Cache` 声明写缓存。响应取 `data[].embedding` 与 `data[].index`，维度不符、条数不符或缺项按不可用处理，这部分不变。按哈希批量取回已算过的向量仍走 `/embeddings/lookup`，它是知新服务自己的接口，不在本条范围内。

6. 客户端删除协议抽象：`LlmWire`、`ChatWire`、`LlmDecoder`、`ChatDecoder` 与 `reasoningItems` 相关字段全部去掉，请求体组装与增量解析各留一个直接可读的实现。`max_tokens` 的兼容分支、两种用量字段名的回退与按模型名判断提供方的写法一并去掉，客户端只写服务端承诺转发的那一种格式。

## 代价与边界

服务端与客户端一起上线：服务端部署之后，仍在使用旧版本客户端的内测用户聊天会立刻失败，直到升级，按 [ADR-0001](0001-开发阶段不向下兼容.md) 不保留 Chat Completions 的回退分支，旧客户端直接得到 404，客户端回答退回本地兜底；这条要写进发版说明。语义索引的嵌入不受影响。服务端按 Responses 转发要求每个来源自己提供 `POST /responses`（流式、工具调用、返回用量），来源不提供时整次请求按 `upstream_failed` 结束，本次没有在代理里写 Responses 到 Chat Completions 的转换。

Chat Completions 的格式在多数开源框架里仍然是最通用的，服务端要把 Responses 转成上游需要的格式，这部分实现落在 `llmproxy`，工作量与维护面从客户端移到服务端，总额大体相抵但集中到一人。

Responses 的流式事件比 Chat Completions 的 `data:` 片段多，客户端按事件名分支，未知事件按忽略处理；服务端如果转发时改写了事件名，客户端读不到正文，联调阶段先核对事件名再核对字段。

工具参数包在 `input_text` 里之后，参数校验的错误说明指到 `input` 这一段，具体字段由 `zod` 那一份声明核对；模型如果改回直接发 JSON 对象，客户端仍按参数形状接收，联调时两种情况都要覆盖。

`store: false` 表示客户端不依赖服务端保存会话；上游如果仍保存，属于提供方设置，见服务端 [ADR-0029](0029-模型来源路由与嵌入代理.md) 的来源配置。

## 替代方案

- 保持 Chat Completions。改动量最小，服务端不用动；没有采纳的原因是协议抽象与 Responses 遗留字段本来就是多来源时代的产物，留着会让下一个人继续为不存在的分支维护预算与去重逻辑。
- 用官方 `openai_dart` 包发请求。类型齐全，但客户端只用一种格式的少量字段，引入 SDK 之后仍然要处理流式事件与失败分类，依赖与版本约束大于手写请求体，评估结论见 [轮子与技术选型评估](../轮子与技术选型评估.md)。
- 让服务端把上游格式统一后再向下暴露 Chat Completions。客户端不动；没有采纳的原因是服务端仍要写转换，而客户端已经只剩一种格式，向下兼容的收益消失。

## 影响

- 客户端：[llm_protocol.dart](../../app/lib/ai/llm_protocol.dart) 重写为 Responses 的请求体、流式事件解析与整段响应读取，[llm_transport.dart](../../app/lib/ai/llm_transport.dart) 去掉线格式抽象并改读事件名，[llm_failure.dart](../../app/lib/ai/llm_failure.dart) 去掉 `reasoningItems`，[agent_loop.dart](../../app/lib/ai/agent_loop.dart) 与 [llm_context_budget.dart](../../app/lib/ai/llm_context_budget.dart) 不再处理推理条目，[buddy_tools.dart](../../app/lib/ai/buddy_tools.dart) 与 [agent_tools.dart](../../app/lib/ai/agent_tools.dart) 把工具参数改成 `input` 条目并在执行前读回对象，[ai_chat_service.dart](../../app/lib/ai/ai_chat_service.dart) 的工具不支持回退只按格式错误触发，[embedding_client.dart](../../app/lib/application/embedding_client.dart) 显式写 `encoding_format`。
- 服务端：[server/api/openapi.yaml](../../server/api/openapi.yaml) 增加 `/v1/llm/responses` 的请求与流式响应，[server/README](../../server/README.md#模型代理)的模型代理一节写明转发的格式与事件名，引用本条的契约说明见 [ADR-0029](0029-模型来源路由与嵌入代理.md) 影响一节。
- 文档：[应用工程说明](../../app/README.md#模型)的请求格式一段、[ADR 索引](README.md)。
- 测试：`app/test/ai/llm_client_test.dart` 与 `app/test/ai/ai_chat_service_test.dart` 改用 Responses 的响应与事件形状。
