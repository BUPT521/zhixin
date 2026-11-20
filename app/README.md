# 知新 · 应用工程

一个懂你的学习搭子，Flutter + SQLite 单机应用。产品定义见 [00](../docs/00-产品定义.md)，数据结构见 [01](../docs/01-ER数据模型.md)，页面与验收见 [02](../docs/02-产品与交互.md)。

## 运行

```bash
flutter pub get
flutter run                 # 接一台 Android 设备或模拟器
flutter build apk --debug   # 出调试包
```

改界面或者逻辑时用热重载，不必每次出包再装到手机。`flutter run` 连上设备之后，改完代码在它的会话里按 `r`，一两秒后新代码就在设备上生效，按 `R` 热重启；模拟器与真机都支持，只有改了原生配置或者新增插件时才需要重新构建安装。

```powershell
pwsh tool/dev.ps1           # 没有设备时先启动第一台 AVD，再执行 flutter run
```

`dev.ps1` 先看 `adb devices` 里有没有已经连上的设备，没有就用 `emulator -list-avds` 里的第一台 AVD 启动模拟器，等到开机完成之后执行 `flutter run`。`-Avd` 指定 AVD，`-Device` 指定设备序列号，`-TimeoutSeconds` 调整等待开机的时间。模拟器单独起进程，脚本退出之后它仍然留着，下一次直接连上。

模拟器按物理像素决定窗口大小、按逻辑像素决定位置，在 Windows 缩放 200% 的屏幕上会开到屏幕上方之外，标题栏拖不到。窗口超出屏幕时，脚本按工作区把它收到右下角，宽高保持 1080:2400 的比例，右边留 64 逻辑像素、下边贴着工作区；窗口本来放得下就不动，`-NoFit` 关掉这一步。

模拟器上的相机是虚拟场景，语音识别走系统服务，数据库、Keystore 与界面行为与手机一致。要验证更接近真实使用的效果，用 USB 连接手机并打开 USB 调试，Android 11 以上也可以用无线调试配对，`adb devices` 能列出之后直接执行 `flutter run`。

语义索引的真机复测用 `pwsh tool/run_adr_0022_probe.ps1 -Apk <探针包>`，探针包由 `flutter build apk -t tool/adr_0022_probe.dart` 构建：`-t` 指定的入口以 `adr_0022_probe.dart` 结尾时，构建脚本给应用 ID 加 `.adr0022probe` 后缀并关闭压缩混淆，探针包因此与正式包并存。脚本在 PLK110 上依次生成 2000 与 20000 条 1024 维向量，记录冷打开、写入、查询、常驻内存与磁盘占用。这一项只做人工复测，不在 CI 与验收流程里执行。

Windows 本机跑 `flutter test` 时，zvec 的实现需要一个本机的 C 库：从 zvec 的 GitHub Releases 下载 0.8.0 版本的 `zvec-sdk-windows-amd64.zip`，核对 SHA-256 为 `7fc16b1bf575d3300f4ae4728f09a6a096b67025d508c350c16302c665ccbbe8`，解压后把 `ZVEC_LIBRARY_PATH` 指向 `<解压目录>\lib\zvec_c_api.dll`，再把同一个 `lib` 目录加进 `PATH`，因为 `zvec.dll`、`zvec_core.dll` 与 `zvec_ailego.dll` 都在这个目录里。没有设置这个变量时，索引契约测试与后台 isolate 的用例会跳过并打印原因；CI 的 Linux 任务会下载并设置好，不受影响。

最低 Android 11（API 30），只出 arm64。构建需要 JDK 21 与 Android SDK 36；CI 的版本固定在 [ci.yml](../.github/workflows/ci.yml)。

## 检查

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

CI 跑的就是这三条。测试用 drift 的内存库在 Dart VM 里执行同一套表结构，不必起模拟器；备份与恢复预检的只读副本用 `package:sqlite3` 打开，和执行器是同一个实现。语义索引的契约测试与后台 isolate 用例在 `ZVEC_LIBRARY_PATH` 没有设置时跳过并打印原因，CI 的 Linux 任务会设置这个变量。账号与云同步的用例用 `test/support/fake_server.dart` 的进程内假服务端走登录、刷新、备份、提交序列与附件的往返，不访问网络；服务端自己的行为由 `server/` 下的 Go 用例覆盖。

## 目录

```
assets/prompts/                              ← 系统提示、上下文说明、请求文本与工具说明，按段落读取
lib/
├── main.dart / app.dart / app_scope.dart   ← 启动、主题、开库与依赖装配
├── app_services.dart                        ← 八组服务（讨论、安排、材料、记忆、设置、数据版本、插件、账号）
├── ai/                                     ← 模型配置、HTTP 客户端、搭子提示词与解析
├── application/                            ← 用例：对话、学习、计划、记忆、设置、账号与云同步、更新检查与反馈
├── data/
│   ├── db/                                 ← drift 表结构与索引（docs/01 的唯一结构来源）、开库、访问协调
│   │   └── drift/queries/                  ← 一张表一个 .drift 文件，由 build_runner 生成类型化方法
│   ├── revisions/                          ← 触发器采集、提交历史、检查点重建、撤销、留存与两类数据包
│   ├── backup/                             ← zip 导出、旧数据版本、暂存校验与分阶段恢复
│   ├── cloud/                              ← 服务端 HTTP 客户端、账号令牌、服务地址、同步状态、发布清单验签与匿名上报状态
│   ├── diagnostics/                        ← 本机崩溃记录与自建 Sentry 上报
│   └── repository/                         ← 讨论、作答、目标、事项、日程、记忆与设置
├── domain/
│   ├── models/                             ← 数据对象、值对象（ClockTime、TimeRange、Score、EvidenceId）与序列化
│   └── rules/                              ← 时间口径、检索切词、记忆范围、本地兜底、版本比较与下一步
├── platform/                               ← 应用信息、提示词资源、发布清单签名公钥与许可
├── plugins/
│   ├── runtime/                            ← 清单、插件接口、四个权限门面、运行时与设置读写接口
│   └── persona/                            ← 人格插件：对象与 800 字校验、内置人格、app_meta 存储
└── ui/                                     ← 现在、记录、记录检索、讨论与讨论内查找、材料与材料查找、系统学习、学习中、安排与安排查找、我的、设置、记忆与记忆查找、账号、云端备份、反馈、关于；页面导航在 navigation.dart，文案在 copy.dart
```

`ai/llm_client.dart` 是模型客户端的入口，只做导出：失败、取消与请求预算在 `ai/llm_failure.dart`，HTTP 收发与 SSE 读取在 `ai/llm_transport.dart`，三种接口的请求组装与增量解析在 `ai/llm_protocol.dart`。`ai/ai_chat_service.dart` 按回答模式装配提示、工具和模型配置，`ai/llm_reply_reader.dart` 将增量或普通响应组装成单步结果，`ai/agent_loop.dart` 按调用顺序执行工具，并将助手消息和配对结果一起追加到续接上下文。工具规格与提案解析位于 `ai/buddy_tools.dart`，工具执行与批量调度位于 `ai/agent_tools.dart`，单步输出上限位于 `ai/llm_config.dart`，作答提问与学习步骤提示在 `ai/buddy_prompts.dart`。

提示词的规则、上下文说明、请求文本与工具说明在 `assets/prompts/`，按 `## 键名` 分段，`pubspec.yaml` 注册为 asset；`platform/prompt_assets.dart` 在启动时读取一次，`ai/prompt_text.dart` 负责解析与取段，`ai/buddy_prompt_builder.dart` 只按请求类型选取段落并替换占位符，`ai/buddy_tools.dart`、`ai/material_page_tool.dart` 与 `ai/search_sources_tool.dart` 的工具说明和参数说明也从同一份资源读取，改文案不需要改 Dart 代码。测试在 `test/flutter_test_config.dart` 里先读取同一份文本，提示词输出与写在代码里时一致；回答质量的第一版评测样例在 `test/evaluation/answer_quality_cases.dart`，覆盖 V1、V3、V6、V11 的提示词条件，真实模型对照按 [02 第 8.4 节](../docs/02-产品与交互.md#84-回答质量对照评测) 记录。

`application/service_runtime.dart` 是服务共用的运行环境：时间口径、数据代次、附件目录与模型调用失败的本机记录。应用根只装配一次，保存每日截止小时、整库恢复与清空之后，服务读到的是新值，不必给每个服务各传一个闭包；测试从 `test/support/service_runtime.dart` 取同一份装配。

安排页的三个表单集中在 `plan_dialogs.dart`，讨论消息与引用展示位于 `discussion_message.dart`，周视图拆在 `plan_week_view.dart`。页面继续负责加载数据与执行用户操作，周视图只接收已加载的周数据，并把选周与点击交回页面。

### 下一阶段的模块化建议

建议先在现有 Flutter 工程内按业务职责收窄接口。`AppServices` 提供八组服务入口，`AppScope` 负责依赖装配、连接替换、时间口径刷新、数据代次与附件维护，仓库字段对页面不可见，整库恢复、导入、导出与恢复点操作已经下沉到 `data/backup/data_version_service.dart`，截止小时由 `application/time_policy_controller.dart` 统一缓存与刷新，撤销经应用层 `application/undo_service.dart` 收口，语义索引配置经 `application/embedding_settings.dart` 保存与应用。下一步的收益主要来自把读路径的失败表达继续往统一的结果类型收，以及把 `plan_page.dart` 的页签继续拆开（[ADR-0014](../docs/adr/0014-流式查询与版本通知.md) 的页面重读已经换成订阅）。

1. **第一批从安排开始，周视图与读取状态已经拆开。** `plan_page.dart` 原先同时控制周视图、预约与改期、事项列表和页面刷新；现在周视图移到 `plan_week_view.dart`，只接收当前周的数据与选周、点击回调，并自己创建、更新与释放日历的事件控制器，页面只保存当前目标周并订阅 `PlanService.watchWeek` 一条流，换周时换一条新流（原 `application/plan_week_reader.dart` 的请求编号与过期结果判断已随订阅下线）。预约冲突检查、整组顺延与撤销沿用现有事务入口，首批以周切换状态、固定安排冲突和一次操作对应一条可撤销提交验收。
2. **随后收拢讨论与作答的回答入口。** `BuddyTimeline` 已经共用消息与回执展示，讨论和作答仍分别维护模型请求、失败兜底与写回流程，可以先共用回答请求的取消、失败分类和数据代次检查，同时让两个用例继续各自保存讨论消息、作答帮助与判断。`LlmClient` 的三种请求格式与流式解码适合按协议整理，`AgentLoop` 继续统一控制整轮预算、重试和工具调用顺序；这一批以无模型可用、停止生成、工具续接及恢复后拒绝旧回答为验收场景。
3. **给查找和引用建立明确入口。** 记录页继续使用 `SearchService` 的筛选与分页，模型上下文通过 `ContextService` 取得限定范围的材料、历史与记忆；两处共享来源标识、原文校验和索引失效规则。材料更正、改归属、撤销与恢复之后，测试应验证旧命中退出检索，同时验证独立复查期间的旧答案仍受访问限制。
4. **在业务接口可独立测试后收窄存储接口。** 应用根只承担装配，版本服务集中持有连接切换、提交回执与恢复后的数据刷新，业务用例通过所属仓库和命令事务写入。建库以 `lib/data/db/drift/tables.dart` 的表类为唯一结构来源，索引也声明在表类上，恢复预检与文档测试都对照实际建库结果；变更时同时核对外键、版本触发器、附件哈希与恢复回滚。

首批改动的验收由界面用例与请求编号两层保证。周视图组件只接收当前周的数据和交互回调，并负责创建、更新与释放日历控制器；安排页统一管理用户选中的目标周和已经加载的周，上一周、下一周、横滑与回到本周走同一套选周逻辑，刷新从当前目标周发起。`test/ui/plan_week_test.dart` 让两次读取反序完成，先交付新周、再返回旧周，验证标题、日历、预约列表和课表仍对应最新一周；固定安排冲突与按提交撤销的要求沿用 [界面验收](../docs/02-产品与交互.md#81-v1v11)。

在现有 [`architecture_test.dart`](test/architecture_test.dart) 中为拆出的周视图添加了针对性检查：组件不能访问 `AppScope`、具体仓库、应用服务或其他页面，只通过传入的数据与回调访问业务操作。独立 Dart package 会增加公开 API、代码生成与测试的维护成本，等某部分有第二个使用方或独立发布需求时再评估。首批的任务指令见 [安排模块化执行提示词](../docs/安排模块化执行提示词.md)。

## 数据

- 业务表主键是 UUIDv7 文本，由仓库在插入前用 `lib/domain/rules/uuid_v7.dart` 的 `newUuidV7()` 生成：前 48 位是毫秒时间戳，同一毫秒内的 12 位序号递增，按主键排序与按写入顺序一致，两台设备各自生成的标识也不会相撞；外键列、版本明细的 `row_key`、撤销与恢复的定位、检查点投影与两类数据包都按这个文本标识，`profile` 仍固定为 1，提交编号、检查点编号与恢复点编号仍是整数（[ADR-0018](../docs/adr/0018-业务表主键改用UUIDv7.md)）。
- 数据库是应用私有目录里的一个 SQLite 文件，业务表、提交历史与附件对象都在同一个库里，表清单、字段与当前版本见 [01](../docs/01-ER数据模型.md)。库文件由 drift 的 `NativeDatabase` 打开，SQLite 使用随包的 `sqlite3`；表结构在 `lib/data/db/drift/tables.dart`，生成文件入库，改表后要跑 `dart run build_runner build`。一条讨论就是一条学习记录，题目由首条用户消息与图片派生，作答直接挂在记录上；事项只保存一段说明，系统学习的步骤就是事项，计划只保存材料范围、顺序与继续位置。备份、恢复校验与版本包里的库副本同样用 `sqlite3` 打开，不再经过 sqflite（[ADR-0012](../docs/adr/0012-结束sqflite与drift并存.md)）。
- 仓库的常规查询和写入在 `lib/data/db/drift/queries/` 中定义，一张表一个文件，在生成时检查表名、列名、参数和可空性。生成读取在共享访问获准后选择连接，生成写入复用命令事务。执行器只保留“执行语句、读回行、开事务”三件事与生成查询两个方法，按表名拼条件的旧接口已经删除。检索里四类字面命中的整段查询仍用手写 SQL（`instr` 与命中位置的子串判断生成查询表达不了；范围规则与存在性判断共用一个表达式），其余查询都在 `.drift` 文件里，字面检索的取舍见 [ADR-0024](../docs/adr/0024-关键词检索并入zvec.md)；版本引擎、备份、恢复校验与撤销按 [ADR-0011](../docs/adr/0011-仓库查询改用drift生成代码.md) 继续使用原生 SQL，口径收敛见 [ADR-0021](../docs/adr/0021-实现口径统一与重构残留清理.md)。
- 表结构与索引只写在 `lib/data/db/drift/tables.dart`（索引用 `@TableIndex`），`schema.dart` 不再有手写 DDL，只提供从表类派生的表名、必需列与索引名，恢复预检与文档测试都对照实际建库结果。值集合只在表类旁维护一份常量，建库 CHECK 由它生成。会话入口、会话状态、时间块状态、事项来源、材料种类与记忆的来源和状态在领域层是枚举，库里存字符串，读到未知值时回落 `unknown` 而不是顶成某个真实取值。
- 关键词检索并入 zvec 索引，业务库不再有 FTS5 表、关键词触发器与 `MATCH` 查询。索引拆成两个 collection：文本 collection 的 schema 固定，片段的正文写进 `content` 字段并建全文索引，只发全文查询；向量 collection 只存向量、来源键、来源版本、片段号、文本哈希与预过滤字段，不存正文。检索时两路各取候选，由应用层按名次倒数融合（RRF，平滑常数 60），向量 collection 不存正文，命中之后按当前记录重新计算摘要。没有配置嵌入模型时只有文本 collection，关键词检索照常可用；配置之后加上向量 collection，换模型只重建这一份（[ADR-0024](../docs/adr/0024-关键词检索并入zvec.md)、[ADR-0030](../docs/adr/0030-服务端不建检索索引.md)）。字面命中仍由业务库的 `instr` 按原字符匹配。
- 索引保存在应用私有目录的 `vector_index/` 下：文本 collection 在 `text/`，向量 collection 在 `vector/`，各自一个 collection 目录与一个同名状态文件，状态文件记录模型键、维度、文本处理版本、数据代次与最近一次刷新的来源数；向量这一份按嵌入模型键分目录，模型、维度或文本处理版本改变时换目录并删除旧目录，正文不重写。来源表有净变化的提交之后等 3 秒补建，启动、整版恢复与导入之后也补建；两份 collection 的状态文件各记已处理到的提交编号，刷新只读该提交之后 `revision_change` 涉及的材料页、消息与作答，删除行按旧行还原来源键、改动行按主键读回当前来源，只重写与重算这些来源，刷新结束时再比一次 `HEAD`，期间又有提交时自动补跑一次。数据代次（`HEAD` 所在提交的 `generation`）变化、历史裁剪或可发送范围变化时退回全量扫描，普通写入不推进代次，只补变化的来源。索引里的向量与片段都能从业务库重建，结构损坏时删除并重建，界面不弹窗，只在本机诊断记录里留一条 `semantic_index` 类的说明；文本 collection 打不开或被占用时关键词与语义检索一起按不可用处理，向量 collection 打不开时关键词一路照常可用，字面命中不受影响；清空全部记录时先释放两份句柄再删除 `vector_index/`，索引不进入数据包（[ADR-0022](../docs/adr/0022-语义索引改用zvec.md)、[ADR-0030](../docs/adr/0030-服务端不建检索索引.md)）。旧的单 collection 目录不再读取，随清空本机数据一起删除，开发阶段不写迁移。
- 记忆召回另用一个纯文本的 collection，目录是应用私有目录下的 `memory_index/`，与语义索引目录同级：每次召回先按 `memory` 表同步有效且未过期的条目，正文或更新时间变了才重写，删除与过期的一并清理，再以来源键列表把排序限制在本次候选之内；只取全文一路，不调用嵌入来源。索引打不开时退回原来的二元组排序；索引不进数据包与版本库备份，清空全部记录时随 `vector_index/` 一起删除（[ADR-0026](../docs/adr/0026-记忆召回改用zvec全文索引.md)）。
- 向量缓存按账号保存在服务端，索引仍只在本机。索引刷新先把同一段正文按 SHA-256 归并，再向知新服务批量查找已经算过的向量（`POST /v1/llm/embeddings/lookup`，返回小端序 FP16 的 base64，解码后按现有方式归一化），只对未命中的片段发嵌入请求，因此换机、索引重建与在模型之间来回切换不必重算已经算过的部分。查找只对知新服务的来源发出：自填 key 直连与本地哈希没有这个接口，旧服务端返回 404 之后本次会话不再尝试，网络失败与 5xx 退回整批嵌入，401、403 与 429 按来源不可用停下本次更新。写缓存只在登录且自动同步开启时声明，嵌入请求带 `X-Zhixin-Embedding-Cache: 1` 之后服务端才保存，检索查询的嵌入不带这个头（[ADR-0030](../docs/adr/0030-服务端不建检索索引.md)）。
- 讨论按记录标识打开，可以没有目标归属，也可以只有图片消息；图片按内容哈希分块存入同一个库的 `asset_object` 与 `asset_chunk`，消息只保存哈希引用，界面读取时把临时文件补回 `question_images/`，同一个哈希只保存一份。
- 材料按页保存，讨论可以带入材料与页码；回答里的引用先按页码取回原文、逐字核对，对不上的标为未核实，用户纠正后旧摘录不再作为依据。也可以直接导入 .docx：原文件按内容哈希与正文片段在同一条提交里写入，片段按 1 起编号，引用显示“第 N 个片段”，这类材料不能手工添加一页。添加一页遇到已有页码时拒绝写入，不覆盖已经校对过的原文；用户明确更正一页时改写内容，修改前后的整行随这次提交留在历史里，保存后提示条可以撤销，材料详情按页列出更正记录。
- 系统学习按材料范围保存步骤、当前页码与完成状态；每一步是学习事项，可以在安排页直接预约，完成状态在系统学习页与事项详情共用。容量规划按每天的可用时段减去课表与已排时间，容量不足时说明先排与缩小范围，只调整用户确认的弹性块。
- 学习判断只保存来源、结论与依据：`assessment(kind=model)` 是模型判断，`assessment(kind=user)` 是用户填写的核对依据，两者都不标记是否核对；用户自评由作答记录中的帮助、独立性与延迟情况推出，独立性只采信用户的三选一，未选择时记为未说明，对错可以暂不判断；`attempt.delayed` 区分当场完成与隔一段时间后重做。
- 普通求助只写讨论、记忆与下一步建议；用户接受建议并明确选择归属后才创建学习事项，不自动改动已有预约。
- 题目不关联知识点；一次作答的对错由用户选择，可以暂不判断，应用内帮助、独立性选择与提交时刻分别记录。
- 本地库只认 01 写明的当前版本。打开时版本不一致就清空旧表并按当前结构重建：开发期只有可丢弃的测试数据，不保留迁移函数。导出包也只接受同一版本，其他版本的包在替换前拒绝。原因与代价见 [ADR-0002](../docs/adr/0002-本地数据不做迁移.md)。
- 每次业务写入形成一条提交，当前数据对应本机 `HEAD`。`GuardedDatabase` 把独立写入与命令事务统一收进同一个入口，触发器采集新增、修改、删除与外键级联，提交时按表和主键合并为净变化；业务行、附件分块、版本明细与 `HEAD` 在同一个事务提交，异常时一起回滚。版本化表拒绝 `REPLACE`，新增表必须登记版本分类；带请求编号的重复写入在重试时返回原提交（旧提交仍然是 `HEAD` 且创建于两分钟内），界面回执指向所属提交；提交身份由 `uid` 表示，推送与服务端去重按它判断，撤销不释放目标的 `request_id`。查看、比较、命名、撤销和整版恢复都从最近的检查点重建，恢复与导入推进数据代次，单项撤销只限当前代次，并核对相关字段在目标提交之后是否又被修改。记忆页的新增、修改与删除同样形成提交，提示条可以撤销；数据版本页与撤销入口共用同一套结构判断，不能撤销的提交在列表里直接禁用并写出原因。设置页的每日截止小时保存成一条提交，保存与撤销后应用根重新读取设置，设置页与归属日口径立即使用新值。
- 页面数据跟随写入更新：版本引擎在提交收尾把这次净变化涉及的表（连带 `revision_commit`、`revision_change`、`revision_ref`）交给 `GuardedDatabase`，事务提交成功之后、独占区释放之前发布一次，回滚的写入与没有净变化的写入不发布。应用服务经 `ServiceRuntime.watch` 给出整屏读法，`GuardedDatabase.watch` 用 `DatabaseGate` 的共享访问重跑读取并只回填最新一次结果；整库恢复、清空、导入与单项撤销之后按全部表补发一次，换连接之后订阅继续有效。通知按表发送，一张表被写入时读它的页面各重读一次，粒度与代价见 [ADR-0014](../docs/adr/0014-流式查询与版本通知.md)。
- 安排页的“整组顺延”把本周未固定的预约一次移动，冲突时整组不改，提交后可从提示或数据版本页整组撤销。暂停目标时取消该目标下未开始的弹性安排与目标状态在同一条提交里，取消范围在事务内读取并一次写入，暂停后也可以从提示条整组撤销；把已取消的预约恢复为待开始时，同样核对课表与其他预约；新增课表时反过来核对已经排好的待开始预约，重叠时拒绝写入并指出冲突的那一条。历史裁剪或清理之后，消息里指向已删除提交的回执去掉提交编号，清理作为一条普通提交写入，没有失效回执时不形成提交。历史裁剪前先重建校验新基线；留存按时间优先：最近 14 天的提交全部保留，更早的按 256 MB 预算裁剪，保留天数可以在数据版本页调整，自动裁剪在空闲检查点之后与手动裁剪共用同一套边界。
- 导出分为两类：当前数据包只含业务投影与仍被引用的附件，导入时追加一条提交；版本库备份是 `VACUUM INTO` 生成的整库快照，包含 `HEAD`、历史、命名版本与附件，恢复前先校验完整性、`HEAD`、重建结果与附件哈希，再走现有的临时副本校验与连接替换流程。两个恢复入口先预检再确认：本机版本恢复列出新增、修改与删除的数量，数据包恢复列出包内 `HEAD`、提交与命名版本数以及当前库规模；整库恢复在替换之前把当前状态保存成一份版本库备份，写入应用私有目录的 `restore_points/`，恢复成功后保留，数据版本页可以回到恢复前，最多保留最近 5 份，恢复点写不出来时本次恢复不执行。两类数据包都排除诊断记录与密钥。导出与备份前按数据库引用核对附件，缺图或哈希不符时中止并列出缺项；版本库恢复前核对完整性、`HEAD`、重建结果与检查点、变更明细和当前投影引用的附件。
- 备份、旧格式数据包与恢复点原先各写一遍校验：现在共用一个暂存库校验（结构版本、对象白名单、`integrity_check`、外键与必需列），旧格式包与版本库备份都走它，完整性检查统一用 `integrity_check`，不再手抄业务查询。

## 界面

界面组件与主题由 Forui 0.28.0 提供，底栏四栏与详情页共用 `ZhixinHeader`、内容区最大宽度及页面边距，详情页使用 `DetailScaffold`，滚动区域通过 `ZhixinSpace.pageInsets` 设定边距。底栏页面（现在、记录、安排、我的）使用 `TabScaffold`：它们外面已经有一层带底栏的 `FScaffold`（见 `home_shell.dart`），键盘弹出时由它让出一次键盘高度，页面自己的骨架不再按键盘缩放，否则内容会被扣掉两个键盘高度，输入区与发送按钮被裁掉，键盘上方只剩一条空白。组件的字号、颜色、留白和圆角从 `context.zhixin` 读取，Forui、Markdown 与 Material 控件的色值都由 `ui/theme.dart` 生成。页面文字不指定字族，中文与西文都跟随手机系统字体，Forui 的每一档文字也在主题里逐档去掉字族，因为指定自定义字族时中文会回落到思源黑体、绕过厂商的系统字体，而且回退字重只有常规与粗体两档，w500 与 w600 会被就近取成粗体；只有时间与计数保留 Forui 自带 Inter 的等宽数字。浅色使用暖白背景和苔绿主色，深色采用相同的颜色角色与布局，选中的导航和分段使用主色浅底，草稿与需要留意的状态使用陶土色。

按钮、输入框、列表、卡片与表单优先使用 Forui，对话框和短提示分别通过 `showZhixinDialog` 和 `showToast` 打开。短提示固定在中下，底部为底栏导航让出高度，位置与留白在 [ui/theme.dart](lib/ui/theme.dart) 的 `zhixinToasterStyle` 里定一次，不随平台改变；停留时间按平台的输入方式分开，手机上 3 秒自动收起，桌面上保留 Forui 默认的 5 秒，带操作按钮的提示两边都停 5 秒。底部面板和日期时间选择器使用 Material，分别通过 `showZhixinSheet`、`showZhixinDatePicker` 与 `showZhixinTimePicker` 打开，样式由同一主题提供。筛选使用 `ZhixinChip`，互斥的视图切换使用 `ZhixinSegmented`，它的每一项按下去时由 `PressScale` 放大几个百分点，松开或切换之后回位，当前项再按不放大；放大只改绘制、不改版面，系统要求减少动态效果时按下与松开直接到终态。业务图标统一从 [Lucide 图标库](https://lucide.dev/icons/) 选取，通过 `FLucideIcons` 引用。

测试里单独构建页面时，外层要补 `FTheme`；页面里会弹提示的，还要补 `FToaster`。少了这两层，页面读不到主题，提示也找不到宿主。

动效与加载按 [动画流畅性优化方案](../docs/动画流畅性优化方案.md) 第 5 节执行，新增页面照下面五条写，不再另立一套：

1. 逐帧变化的透明度只用 `FadeTransition`，不用 `Opacity` 组件；逐帧位移的子树先包 `RepaintBoundary`，让动画只动合成层。`FadeIn`、`ExpandReveal`、`TabSlideStack` 与 `SlideSwap` 已经把这三件事做在组件里，页面直接用。
2. 动画期间不改布局：输入框聚焦、分段选中这类状态变化只插值颜色，边框宽度与字重固定，不让整块重新布局。
3. 切栏、切页签与推入页面时读取立刻发起，回填前调用 `context.afterTransition()`，结果等过渡结束再交给界面；已有数据时返回不重播淡入，也不显示转圈。
4. 常驻但不可见的内容一律包 `TickerMode(enabled: false)`；底栏与页内页签用 `TabSlideStack` 常驻，换周这类同一块位置换内容用 `SlideSwap`，切换只换显示，输入、筛选、滚动位置与 `MaterialList` 的状态因此不丢。底栏、页签与换周按整幅页宽滑入滑出，其余位移不超过 24 像素。底栏传入 `TabSlideStack.onSwipe` 之后还可以左右划动切换：拖动途中按手指位移换算进度，松手按划过的比例（约三分之一页宽）与同方向的滑动速度（300 逻辑像素每秒）决定切过去还是退回，页面里能横向滚动的内容先接走横拖；划到的那一栏由调用方把 `index` 换过去，组件不自己改。页内页签不接划动，只按 `ZhixinSegmented` 点击切换。
5. 页面路由的过渡在 `ThemeData.pageTransitionsTheme` 里配一次（Android 用系统的预测性返回，普通推入由框架淡入前推；iOS 与 macOS 保留系统滑回手势；桌面淡入加右推 24 像素），各页不再各写一套；减少动态效果时直接给终态。`MaterialPageRoute` 照常写，过渡由主题统一决定。

首读占位一律用 `ListSkeleton`（与卡片同高的静态块），页面不再用居中转圈：转圈只占一行，内容读完之后下方整体下移，页面跟着跳动。详情页在骨架期间保留标题栏，列表页按将要出现的卡片高度摆好灰条。一级界面切进来时已经在后台读过首屏的二级页面直接用结果，不再摆骨架。只有没有版面可占位的等待仍用 `PageLoading`，即应用启动、相机预览与照片解码三处：Forui 的圆形指示默认取正文字号，手机上只有 18，看上去只是一个图标，所以这里定成 36 的直径并取主色；按钮、列表行与照片上的指示仍用 `sm`、`xs`，大小跟着所在控件走。这类差异在 Forui 的样式里改，界面里的 Material 只保留底部面板与日期时间选择两处，同一种“正在读取”因此只有一套组件。

页面之间的跳转统一经 [ui/navigation.dart](lib/ui/navigation.dart) 的一页一个函数打开，页面不互相 import，路由也只在这个文件里构造；`PlanPage` 的底栏入口与 `PlanPage.detail` 详情入口分开，详情不参与切栏。忙碌指示用 `FProgress` 与按钮内 `FCircularProgress`，错误与失败说明统一用 `InlineNotice`（可带重试），表单字段的就地校验文字保留在字段旁。确认框统一经 `confirmZhixin` 与 `showZhixinAlert` 打开，按钮形状与取消文案不再由调用方各写一份。文案集中在 [ui/copy.dart](lib/ui/copy.dart)（角色名、页签名与空态句式），时钟与日期格式集中在 [ui/format.dart](lib/ui/format.dart)，间距与圆角从 `ZhixinSpace`、`ZhixinRadius` 取，竖直排列的两个条目之间留 `space.sm`，历史记录、更正记录与步骤这类逐行排列的列表里相邻两行留 `space.tight`，两张独立卡片的描边不贴在一起，动效时长与曲线只从 [ui/motion.dart](lib/ui/motion.dart) 取。页面数据统一用 [ui/live_view.dart](lib/ui/live_view.dart) 的 `LiveView` 订阅应用服务给出的流：写入、撤销、导入与换库之后的重读由数据层推送，页面不再在保存或跳转返回后自己重读（[ADR-0014](../docs/adr/0014-流式查询与版本通知.md)）。读取没有完成时不提供下拉刷新这类手势：数据本来就跟着写入回来，手势重跑的是同一条读法，恢复交给内容区的 `InlineNotice` 与“重试”，已经显示的内容保持不动。插件页与人格页读的是不形成提交的 `app_meta`，仍用 [ui/data_version_watcher.dart](lib/ui/data_version_watcher.dart) 在整库恢复与清空之后重读。

一级界面切进来时，[application/prefetch_service.dart](lib/application/prefetch_service.dart) 在后台读它下面几个二级界面的首屏（[ADR-0033](../docs/adr/0033-一级界面预读二级页面首屏.md)）：记忆页与数据版本页各一屏，设置页的模型配置、账号、可选模型与索引概况，云端备份列表（只在登录之后），账号与云同步页的首屏（与“我的”的账号卡共用同一份账号、同步状态与额度），“这周能做什么”的当前周结果，语义索引设置，人格与插件页的 `app_meta`，以及记录查找与安排查找的范围选项。预读只在对应的一栏切进来之后开始，首页启动时不读这些内容；结果保留 5 分钟，页面打开时先用这一份结果，`LiveView` 的 `initial` 因此不必先摆骨架，随后按各页原来的读法继续订阅或刷新。设置、云端备份、账号与语义索引设置只取用一次，之后再打开按当前状态重新读。学习、讨论、材料详情、系统学习与事项详情按具体条目打开，进入一级界面时还不知道要打开哪一条，仍在打开时读。

## 外观

设置页的“深浅色”可以选跟随系统、浅色或深色，选择立即生效。取值写在应用私有目录的 `theme_mode` 文件里，不随数据包导出或恢复：主题要在数据库打开之前的第一帧生效，外观也只是这台手机上的偏好。深色沿用浅色的颜色角色，只改背景、卡片、文字与强调色的明度；相机取景与框选手柄压在图片上，保留黑白叠加层。

## 模型

设置页填接口风格、接口地址、模型名与 API Key，默认 `Chat Completions`、`https://api.deepseek.com/v1` 与 `deepseek-flash`。key 存在 Android Keystore，不进仓库、不写日志；应用不内置密钥。登录用户可以在设置页把模型来源改为“知新服务”：接口风格固定为 Chat Completions，地址由服务地址拼出 `/v1/llm`，访问令牌代替 key，令牌过期时先刷新再用，额度用完时改用自己的 key；客户端入口在 `lib/application/account_service.dart` 与 `lib/ai/ai_chat_service.dart` 的配置来源里，取舍见 [ADR-0009](../docs/adr/0009-API后端采用Go与分层框架.md)。接口风格由用户显式选择，不按域名猜：同一家服务商的不同地址可能只支持其中一种，猜错时只能看到 404 或 400。

三种风格共用一个传输层。地址只填域名时补 `/v1`，Anthropic 按 `base/v1/messages` 拼接（`https://api.deepseek.com/anthropic` 因此得到 `/anthropic/v1/messages`）。Chat Completions 发 `messages`、`tools`（`{type:function,function:{…}}`）与 `stream_options.include_usage`，输出上限在 OpenAI 官方用 `max_completion_tokens`、其余实现用 `max_tokens`，指向 DeepSeek 时带 `{"thinking":{"type":"disabled"}}`；Responses 发顶层 `instructions`、`input`（`input_text`、`output_text`、`input_image` 的 data URL，工具用 `{type:function,name,parameters,strict:false}`）与 `max_output_tokens`，指向 DeepSeek 时带 `{"reasoning":{"effort":"none"}}`；Anthropic Messages 用 `x-api-key` 与 `anthropic-version: 2023-06-01` 鉴权，system 放顶层，工具用 `input_schema`，图片是 `{type:image,source:{type:base64,…}}` 块，指定工具时 `tool_choice` 取 `{"type":"tool","name":…}`。

流式响应按 SSE 规范读取：一个事件可以由多行 `data:` 组成，空行才分发，注释行与 `event:`、`id:`、`retry:` 字段不影响负载，首行带 BOM 也能读。评估过 `sse`、`flutter_client_sse`、`simple_sse` 等现成包，都不能同时满足“POST 流、逐行超时与取消、无空行收尾时 flush”，因此保留自研解析器。三家的结束标记不同：Chat Completions 认 `[DONE]` 或非空 `finish_reason`，Responses 认 `response.completed`／`response.incomplete`（正文只补还没发过的后缀，工具调用按 `item_id` 归并，`output_item.done` 的完整参数覆盖分片），Anthropic 认 `message_stop`（工具参数由 `input_json_delta` 分片拼接，`stop_reason` 为 `max_tokens` 算截断）。没有结束标记时按截断保留已经生成的正文并提示；`content_filter`、`response.failed`、Anthropic 的 `error` 事件按服务端错误处理。非 2xx 的响应体会读出服务端自己的说明，便于定位 key、额度与模型名的问题。

回答正文使用 Markdown，模型可以用 `read_material_page` 读取本轮检索命中的原文，并在收到工具结果后继续回答。`propose_memories`、`propose_next_steps`、`propose_citations`、`propose_study_steps` 与 `propose_assessment` 提交的内容暂存在本轮，参数有误时丢弃对应提案，普通回答有完整正文即可结束。Chat Completions 通过 `tool_call_id` 配对调用与结果，Responses 通过 `function_call_output` 的 `call_id` 配对并带回本轮的推理条目，Anthropic Messages 把同一步的 `tool_result` 集中在下一条用户消息中。每轮的停止条件、材料范围与保存边界见 [00 第 9 节](../docs/00-产品定义.md#9-回答与工具调用)。

回答与记忆分开保存：用户明确说出的记忆在回答落库后单独写入，回答下方给一张可以撤销的卡片，写入失败只提示并保留待确认卡片，不回滚正文；模型推断的记忆先出确认卡片，点「记下」才写入，点「不记」收起。记忆写入形成一条提交，回执保存提交编号，讨论页可以按提交撤销；撤销后卡片回到待确认，同一批写入的多条记忆一起撤销。接受建议后创建的学习事项在同一条提交里记下已接受标题，回执同样指向这次提交。回答里的 Markdown 外链图片不自动加载，只显示可点击的提示，用户点击后才交给系统浏览器打开。

官方 OpenAI Responses 请求保持 `store: false`，并用 `include: ["reasoning.encrypted_content"]` 请求加密推理条目，客户端在工具续接时将条目和配对结果一并传回。[OpenAI Responses 请求文档](https://developers.openai.com/api/reference/resources/responses/methods/create)

设置页可以填写模型的上下文上限，应用据此估算输入容量并预留输出空间。连接测试用一次最小工具请求检查模型或地址能否返回可解析的工具参数。

没有配置、断网或调用失败时，讨论、题目、尝试、日程与记忆仍可查看与记录，下一步由本地规则给出，并标明来源。

## 账号与云同步

账号可选。`lib/data/cloud/server_client.dart` 是服务端的最小 HTTP 客户端，只拼路径、解 JSON 与把错误统一成 `ServerProblem`；账号会话、令牌刷新、邮箱验证、找回密码、退出登录、删除账号与“知新服务”配置在 `lib/application/account_service.dart`，令牌与设备标识只写 Android Keystore（`lib/data/cloud/account_store.dart`），服务地址、自动同步开关与上次同步的账号和实例写在应用私有目录的 `cloud.json`（`lib/data/cloud/cloud_preferences_store.dart`），不进入数据库、数据包与整库备份；同步的两个位置在库里的 `revision_cursor`，随整库备份一起恢复，数据包不含它。没有保存地址时使用 `cloud_preferences_store.dart` 里的编译时默认值，正式包指向项目组的第一套实例，本地联调用 `--dart-define=ZHIXIN_SERVER_URL=...` 覆盖；保存地址后调用 `/readyz` 核对服务端就绪与 schema 版本，账号页把这个地址标为默认或已修改。正式包只接受 https 地址，明文 http 只在显式开启 `ZHIXIN_ALLOW_INSECURE_SERVER` 的联调构建里可用；带令牌的服务端请求不跟随跨域重定向，同源重定向才继续。会话、进行中的刷新与同步位置都绑定到服务实例来源与账号，换实例或换账号时旧响应按身份代次丢弃并暂停自动同步，首次把本机记录上传到某个账号前要确认。

注册之后的邮箱默认未确认，账号页提供发送与确认验证码的入口，验证码只以六位数字邮件送达，服务端存 HMAC；未确认时找回密码收不到重设验证码。登录卡的“忘记密码”切到邮箱、验证码与新密码三段表单，重设成功之后服务端作废该账号的全部会话，本机清掉登录状态并回到登录表单。删除账号要先在确认框里重新输入当前密码，服务端回 401 `invalid_credentials` 时只提示密码错误并保留当前登录；“清除云端数据”调用 `DELETE /v1/cloud`，服务端回 409 时提示稍后重试，成功后页面显示完成状态并询问是否恢复自动同步。账号页同时读 `/v1/llm/quota` 显示今日已用与每日额度，设置页在“知新服务”来源下列出 `/v1/llm/models` 返回的允许模型；这两处读取失败只给一行说明，不影响本机功能、备份与同步。

云端备份在 `lib/application/cloud_backup_service.dart`：上传时用与“备份版本库”相同的 `VACUUM INTO` 快照生成 zip，计算 SHA-256 之后按契约上传，服务端按保留份数删除最旧的；列表、下载与删除都按账号隔离，下载后先核对响应头里的哈希，再交给本机已有的预检、确认与恢复点流程替换数据库。附件随同步上传，服务端按账号累计字节，超过账号总量配额时返回 413 `storage_full`，页面显示已用量与上限并停止本轮上传，不逐个重试。页面在 `lib/ui/account_page.dart` 与 `lib/ui/cloud_backup_page.dart`，从“我的”页的账号卡、设置页模型段与数据版本页进入。

增量同步在 `lib/application/sync_service.dart`。第一次同步先拉取服务端已有的提交并在本机应用，再把当前业务投影作为基线上传，之后只推送新提交；拉取到的远端提交经 `RevisionService.applyRemoteCommit` 在本机生成一条同样净变化的提交，撤销与数据版本页照常可用，远端提交的 uid 沿用到本机，拉取时按 uid 判断远端提交是否已经应用，重复下发不会叠加；推送时协议里的 `request_id` 字段填提交的 uid，服务端按它永久去重。拉取时被远端取代的本机格子登记在 `sync_shadow`，推送时按格去掉被遮蔽的部分再推剩余，剩余为空的提交不推但推送位置照常前进，维护列 `updated_at` 不记冲突（[ADR-0040](../docs/adr/0040-数据版本的提交身份与同步变基.md)）。附件按内容哈希随提交上传与下载，拉取时核对哈希；服务端位置变化返回 409 时先拉取再重推，同一字段两台设备同时修改时后到达的覆盖先到达的，取舍见 [ADR-0023](../docs/adr/0023-首次同步上传基线.md)。应用根在提交之后延迟几秒排一次同步，账号页可以手动立即同步；同步失败只记一条说明与本机诊断，本机读写不受影响。

`lib/application/sync_service.dart` 只依赖 `GuardedDatabase`、版本服务与账号服务，不换库、不清空；远端提交的应用走 `GuardedDatabase.command`，因此与普通写入共用数据库独占区、表通知与版本通知。同步的两个位置在库里的 `revision_cursor`（`sync.pushed` 与 `sync.server_head`），带“账号编号 + 实例来源”的 `scope`：退出登录、删除账号与重设密码只把推送位置改成不阻塞、位置与 `scope` 保留，重新登录同一身份时从原位置继续增量同步；清除云端数据时两个位置与恢复标记一并删除，下一次同步按首次基线重建。整库恢复把库换成备份那一刻的内容之后，本机补记一条 `restore` 提交（恢复前后的差异，含删除），下一轮手动同步先确认“云端会改成恢复后的内容”，确认之后跳过拉取、只把这条差异推上去，两个位置收敛到当前服务端位置与本机 `HEAD`，待对齐期间自动同步不排期。

## 使用统计

不登录时的匿名活跃上报在 `lib/application/active_report_service.dart`，本机状态在 `lib/data/cloud/telemetry_store.dart`：安装标识首次启动时随机生成并保存在应用私有目录的 `telemetry.json`，不进入数据库、数据包与整库备份；应用根在首帧之后的空闲任务里调用一次，每天最多成功一次，失败静默重试一次并写本机诊断。登录之后再启动直接跳过，登录用户的活跃由服务端按请求日期统计。首次启动用一次说明讲清采集内容与用途，设置页“诊断”下方另有“使用统计”开关，默认开启、可以关闭；关闭之后不再上报，已经上报的记录保留，口径见 [ADR-0019](../docs/adr/0019-留存统计用匿名上报.md)。

## 插件

插件随应用编译，运行时只加载第一方插件，不在运行时下载或执行第三方代码。目录与运行时第一版在 M1 建立，形态与权限的取舍见 [ADR-0010](../docs/adr/0010-客户端插件的两种形态与权限.md)，页面口径见 [02 第 3.15 节](../docs/02-产品与交互.md#315-插件与人格)，验收项见 [02 第 8.6 节](../docs/02-产品与交互.md#86-插件与人格验收)。

- 运行时基础设施在 `lib/plugins/runtime/`。`plugin_manifest.dart` 是不可变清单，字段为标识、名称、版本、说明、类型与四项权限，`validatePluginManifest` 返回可以直接显示的错误；人格插件声明任意一项权限都算不合格。`plugin.dart` 是 `FirstPartyPlugin` 接口，暴露 `manifest`，能力插件从 `start(PluginAccess)` 进入。`plugin_access.dart` 是网络、读数据、提交草稿与调用模型四个门面，未声明的权限在调用点抛 `PluginPermissionDenied`，不做静默降级；已经声明但本期没有接入的能力抛 `PluginCapabilityUnavailable`。`plugin_runtime.dart` 注册插件、读写启停状态、拒绝未知标识，并通过 `activePersonaPrompt` 给出当前人格段落。`plugin_metadata_store.dart` 是运行时依赖的设置读写窄接口，生产实现是 `lib/data/repository/plugin_metadata_store.dart` 里的 `SettingsPluginMetadataStore`。
- 目录规则：运行时基础设施放 `lib/plugins/runtime/`，单个插件放 `lib/plugins/<插件标识>/`。插件目录不 import `data/` 与 `ui/`，不持有数据库连接，也不依赖 Flutter；`test/architecture_test.dart` 对这三个边界逐条检查。
- 人格插件在 `lib/plugins/persona/`。`persona.dart` 定义 `Persona` 与按码位计数的 800 字校验，超过时由 `validatePersonaText` 说明超出的字数，不静默截断；`builtin_personas.dart` 是两个内置人格；`persona_catalog.dart` 读写 `app_meta` 并切换当前启用项；`persona_plugin.dart` 是人格插件的清单与本体，清单不声明权限。人格段落由 `ai/buddy_prompt_builder.dart` 拼在核心规则之后、当前时间与记忆之前，启用人格时另有一条规则说明用户本轮说明、人格与记忆讲解偏好的顺序与边界；停用后下一次请求不再带人格段落，读取到超长文本时用 `truncateCodePoints` 兜底。
- 设置键写在 `app_meta`：`persona.items` 保存人格 JSON 列表，`persona.active` 保存当前启用人格（空串表示未启用），`plugin.enabled.<插件标识>` 保存启停状态（`1` 或 `0`，没有写过时默认启用）。写入经 `SettingsRepository.setMetadata`，不形成提交，也不进数据版本页；整库备份包含 `app_meta`，恢复或清空之后下一轮回答与重新打开的页面都读恢复后的状态，当前数据包不包含这些设置。
- 本期做运行时骨架、人格插件、“我的”页的“插件”与“人格”两个入口以及四条调用点检查；能力插件、课表导入、B 站与 ICS 读取、第三方插件、沙箱与服务端分享码留到 M3。插件不保存第三方账号的密码、Cookie 或令牌，也不把学习内容发给第三方工具服务。

## 发布

### 签名

正式包只在 Actions 里出，本机不出。CI 用仓库 Secrets 里的四项配置还原 keystore，
再生成 `android/key.properties`；四项缺一项，发版任务会在“检查签名 secrets”一步直接失败，
不会悄悄打出一个 debug 签名的包。

| Secret | 内容 |
|---|---|
| `RELEASE_KEYSTORE_BASE64` | keystore 文件的 base64，用 `base64 -w0 release.jks`（macOS 用 `base64 -i release.jks`）生成 |
| `RELEASE_KEYSTORE_PASSWORD` | keystore 口令 |
| `RELEASE_KEY_ALIAS` | 密钥别名 |
| `RELEASE_KEY_PASSWORD` | 密钥口令 |

keystore 与口令由发版人保管，仓库与本机工程目录都不放：CI 把还原出来的 keystore 写到 runner 的临时目录，
`key.properties` 里用绝对路径引用它，发版结束随 runner 一起销毁。发版任务在构建之后用 `apksigner` 核对证书
不是 debug 证书，并对包体记录版本、提交与 SHA-256，随后用 Ed25519 私钥产出发布清单的哈希与签名材料。

### 发布清单签名

发布清单里的每一版安装包另有一把 Ed25519 签名密钥，用来让应用确认清单与安装包没有被替换。私钥的 PKCS8
编码以 base64 放在仓库 Secret `RELEASE_SIGNING_KEY_BASE64` 里，CI 在发版任务的“签名与清单”一步用它签名；
这一项与 keystore 的四项一样，缺失时发版任务直接失败，不会产出一份没有签名的清单片段。密钥的生成与保管
由发版人完成，命令如下：

```bash
openssl genpkey -algorithm Ed25519 -out release-signing.pem
openssl pkey -in release-signing.pem -pubout -out release-signing.pub.pem
base64 -w0 release-signing.pem   # 结果填入仓库 Secret RELEASE_SIGNING_KEY_BASE64
```

签名对象是安装包 SHA-256 的小写十六进制字符串本身，共 64 个 ASCII 字节，不加换行，也不签文件内容；
CI 用 `openssl pkeyutl -sign -rawin` 对这段字符串生成 64 字节签名，再转成 base64 写进 `app-release.apk.sig`，
同时产出 `app-release.apk.sha256`，两个文件与安装包一起上传为构件，并在 step summary 里给出可以直接填进
发布清单的 JSON 片段。公钥以常量形式内置在应用里：把 `release-signing.pub.pem` 的内容原样填进
`lib/platform/release_signing_key.dart` 的常量，或者构建时用
`--dart-define=RELEASE_PUBLIC_KEY_PEM="-----BEGIN PUBLIC KEY-----…"` 传入，两种方式取其一。更新检查核对 HTTPS 地址和 SHA-256 格式，并使用随包公钥对哈希字符串验签，随后下载安装包并核对实际哈希。签名、公钥或哈希缺失时，应用不提示更新。官方发版任务核对签名私钥是否与仓库内置公钥配对。启动后的自动检查与设置页的“检查更新”走同一套流程，本次启动只自动
检查一次。私钥与 keystore 一样只由发版人保管，不进仓库与本机工程目录；换密钥意味着旧版本应用无法验证
新清单，发版说明要写明这一点，并在应用内置公钥的下一次发版里同步更新。


正式包在 Actions 里手动运行“CI 与发版”，用仓库 Secrets 里的签名配置生成；本机不出正式包。版本号按 [03 第 3 节](../docs/03-团队分工与协作.md#3-交付节奏)递增，取值以本目录 `pubspec.yaml` 的 `version` 一行为准，只由发版人（见 [03 第 2 节](../docs/03-团队分工与协作.md#2-角色)）在发包前修改；开发包的版本名带 `-dev` 且按 `com.zhixin.app.dev` 另装一个应用，“我的”页的“关于”显示构建时写入的构建名与构建号，不另存版本常量；许可页同时列出知新自身的 MIT 许可与第三方组件许可，知新自身的许可从 `platform/app_license.dart` 读取，测试会核对它与仓库根目录的 `LICENSE` 同文。

