# 知新 · 语义索引接入 zvec 的方案

> 本文记录把语义索引的存储引擎从替换前的 SQLite 向量表换成 [zvec](https://github.com/alibaba/zvec) 的做法：改哪一层、数据怎样落盘、每个操作怎样对应、构建与测试怎样调整，以及按什么顺序实施。范围是 2026-11-16 `main` 上的 `app/lib/data/vector/` 与 `semantic_index_service.dart`；关键词检索、业务库与服务端不在范围内。决定本身记在 [ADR-0022](adr/0022-语义索引改用zvec.md)（已采纳，第 1 至 6 步已完成），本文是它的实施说明，两处不一致时以 ADR 为准。

## 1. 结论

替换只发生在 `VectorStore` 接口以下。`SemanticIndexService`、证据检索与界面继续通过 `VectorStore` 读写，后台 isolate 的消息协议保留，换掉的是 isolate 里实际持有数据的那一层：替换前是一个 SQLite 文件同时存放元数据表 `vector_entry` 和 `vec0` 虚拟表，现在是一个 zvec collection 加一个状态文件。接口的调整集中在几处：`indexedSources` 改为按调用方给出的来源键读取，新增 `sourceCount`，`search` 增加一个范围预过滤参数，`pruneSources` 改为返回删除的向量条数，完整清单见 [ADR-0022 实施方案第 1 节](adr/0022-语义索引改用zvec.md#1-接口改动)。打开与关闭的顺序、损坏后的处理、发布与回退也记在 ADR-0022 的实施方案里，本文不重复。

索引类型用 Flat（精确检索）与余弦距离，不做量化。每个嵌入模型一个 collection 目录，模型、维度或文本处理版本改变时换目录、删旧目录。zvec 没有跨文档事务，`replaceSource` 先写其余片段、最后写 0 号片段，0 号片段承担提交记录的作用，中途退出时下一次刷新会把这个来源判为“需要重建”。关键词检索继续使用 [ADR-0013](adr/0013-关键词检索改用FTS5.md) 的 FTS5。

这次替换的收益主要来自检索路径。zvec 在一次调用里完成范围过滤并返回片段正文，因此可以省去逐条回表，减少材料或讨论范围的检索候选数，同时去掉了旧引擎构建钩子对 clang 工具链的依赖。主要代价是安装包，arm64 release APK 会存放未压缩的原生库，包体实测见 [ADR-0022 代价与边界](adr/0022-语义索引改用zvec.md#代价与边界)。

替换前使用的 SQLite 向量实现（内置 sqlite-vec 0.1.9）也支持 `vec0` 元数据列与辅助列，两条路线的比较见第 3.1 节，没有采纳的原因见 ADR-0022 的替代方案。

## 2. 现状

| 文件 | 职责 |
|---|---|
| [vector_store.dart](../app/lib/data/vector/vector_store.dart) | `VectorStore` 接口；`DirectVectorStore` 在同一线程里直接调用 `VectorIndex`，只用于测试 |
| [vector_store_isolate.dart](../app/lib/data/vector/vector_store_isolate.dart) | `IsolateVectorStore`：后台 isolate 持有索引，界面线程按操作名发送请求，`_runOperation` 分派 |
| [vector_index.dart](../app/lib/data/vector/vector_index.dart) | `VectorIndex` 同步接口，以及 `StoredVector`、`IndexedSource` 与 `VectorPrefilter` 值类型 |
| [zvec_vector_index.dart](../app/lib/data/vector/zvec_vector_index.dart) | `ZvecVectorIndex`：一个模型键一个 collection 目录，状态写在同名的 JSON 文件里 |
| [memory_vector_index.dart](../app/lib/data/vector/memory_vector_index.dart) | `MemoryVectorIndex`：纯 Dart 的余弦距离排序，服务层测试与契约测试用 |
| [semantic_index_service.dart](../app/lib/application/semantic_index_service.dart) | 刷新（比对来源版本、嵌入、写入、清理）与检索（取候选、逐条核对业务记录与范围） |
| [app_paths.dart](../app/lib/platform/app_paths.dart) | `vectorIndexPath` 指向 `filesDir/vector_index/`，`vectorLogPath` 指向缓存目录下的 `zvec_logs/` |

检索由一次 `query` 带回 `source_key`、`chunk`、`content`、`source_version` 与 `locator_json`，不再逐条回表；服务层随后对每个候选调用 `repository.current` 与 `repository.inScope` 核对。替换前的 `vec0` 表只建了向量列，检索时不知道范围，限定到某个目标或材料时范围外的向量会挤占候选，服务层把候选数放大到 `limit × 20` 并封顶 400，范围很窄时仍可能漏召回；现在材料范围与回答前无目标范围可以下推，候选回到 `limit × 4`，目标范围仍按 20 倍处理。

## 3. 测得的数据

数据来自本机沙箱（x86_64，2 核），zvec 用 PyPI 上的 0.8.1，`sqlite-vec` 用 PyPI 上的 0.1.9。Dart SDK 与 Python 包调用的是同一个 C 引擎。向量为 1024 维（`embedding_config_store.dart` 的默认维度），每个来源 4 个片段，共 20000 个片段，约相当于 640 万字正文。

| 项目 | sqlite-vec `vec0` | zvec Flat FP32 | zvec Flat INT8 | zvec HNSW FP32 |
|---|---|---|---|---|
| `optimize` | 不适用 | 0.1 s | 0.1 s | 83.9 s |
| 取前 20 条 | 35 ms | 4–5 ms | 3 ms | 4–7 ms |
| 取前 400 条并回表 | 48 ms + 2 ms | 一次调用返回 | 一次调用返回 | 一次调用返回 |
| 磁盘占用 | 89 MB | 83 MB | 104 MB | 约 90 MB |

写入两万条，sqlite-vec 用 3.3 秒，zvec（HNSW 配置）用 2.2 秒。另外核对了几项行为：余弦距离的得分是 1 − cos，取值 0 到 2、越小越近，与 `vec0` 的 `distance` 口径相同，`semanticMatchScore` 不用改；主键可以包含 `:`、`/`、`#`；未执行 `optimize` 的新写入也能被检索到；`deleteByFilter` 支持 `source_key = '…' and chunk >= n` 这样的组合条件，`not in` 带 4900 个键时耗时约 19 ms，带 19,900 个键（表达式约 935 KB）时约 244 ms；`fetch` 遇到不存在的主键会直接略过；collection 关闭再打开后条数不变。

这组数据支持三个取舍。Flat 在两万条的量级上已经是毫秒级，HNSW 在两核上建一次索引要 84 秒，放到手机上会长时间占住后台线程，所以第一版用 Flat。INT8 在 Flat 上会同时保留原始向量与量化向量，磁盘反而增大，第一版不量化。sqlite-vec 在同样规模下是几十毫秒，对用户来说同样感觉不到，因此这次替换的理由不能写成“变快了”。

### 3.1 与改造 `vec0` 表结构的比较

sqlite-vec 0.1.6 起，`vec0` 可以声明元数据列（参与 KNN 内部过滤）与以 `+` 开头的辅助列（随结果返回、不参与过滤）。在同一份两万条数据上，把 `kind`、`material_id` 建成元数据列、`content` 与 `source_key` 建成辅助列，测得：

| 项目 | `vec0` 元数据列与辅助列 | zvec Flat |
|---|---|---|
| 不带过滤取前 20 条（含正文） | 37 ms | 4–5 ms |
| `material_id = ?` 过滤后取前 20 条 | 19 ms，返回满 20 条 | 1 ms 以内（以 `source_key in` 三个键测得） |
| `kind != 'material_page'` | 支持 | 支持 |
| `material_id in (…)` | 支持，但每个取值各返回 k 条，需要再截断 | 支持 |
| `… or …` | 不支持，报错 | 支持，可嵌套 |
| 原生库增量 | 无 | 解压后约 33 MB |
| 文档级写入事务 | 有，与 `vector_entry` 同一个 SQLite 事务 | 无，靠 4.5 节的写入顺序 |

改造 `vec0` 的做法是：范围用一个派生的元数据列表达，例如材料页存材料 ID、其他来源存空串，查询写成 `scope_material in ('X', '')` 再截断；正文与定位信息放进辅助列，`vector_entry` 只留给 `indexedSources` 与清理使用。这样能拿到第 4.6 节的大部分收益，包体不变，事务也保留。zvec 多出来的是一套通用的过滤表达式、约七倍的检索速度，以及以后接稀疏向量与混合检索的余地，代价是包体和自己维护写入顺序。

## 4. 现行结构

### 4.1 分层

```
SemanticIndexService ──► VectorStore（接口，界面线程）
                              │
              ┌───────────────┴───────────────┐
      IsolateVectorStore                DirectVectorStore（测试）
              │ 消息协议不变                     │
              ▼                                 ▼
        VectorIndex（同步接口，后台线程）
              ├── ZvecVectorIndex   运行时
              └── MemoryVectorIndex 纯 Dart 暴力检索，单元测试用
```

`VectorIndex` 是同步接口，运行时的实现是 `ZvecVectorIndex`，原来的 SQLite 实现已在第 6 步删除。`MemoryVectorIndex` 用 Dart 列表做余弦距离排序，承担服务层测试，并与 `ZvecVectorIndex` 一起接受契约测试的同一组用例，内存实现因此不依赖原生库。

### 4.2 磁盘布局

```
filesDir/vector_index/
  <model_key 的短哈希>/        # 一个 zvec collection
  <model_key 的短哈希>.json    # model_key、dim、text_version、epoch、built_at、source_count
```

`AppPaths.vectorIndexPath` 指向 `vector_index/` 目录。每个 collection 配一个同名的状态文件，模型在两个键之间来回切换时，新旧 isolate 各写各的文件。当前模型的 collection 打开成功之后，再删除其他模型键的目录与状态文件；删除之前先试着打开一次对方的 collection，对方仍被另一个 isolate 占用就跳过，状态文件只在对应的 collection 已经删掉或不存在时才删除，细节见 [ADR-0022 实施方案第 2 节](adr/0022-语义索引改用zvec.md#2-打开关闭与并发)。旧版索引留下的 `vector_index.db`、`-wal`、`-shm` 在同一步删除；按 [ADR-0002](adr/0002-本地数据不做迁移.md)，语义索引本来就是可以从业务库重建的派生数据，不做迁移，切换在 0.2.0 之前完成，库里只有测试数据，旧索引直接重建。

状态文件用“写临时文件、再改名”的方式原子替换。它只在打开、清空和一次刷新结束时写入，不随每个来源写。

### 4.3 文档结构

主键是 `<source_key>#<chunk>`。消息和作答的 `source_key` 形如 `种类:UUID`，材料页还有一个以冒号分隔的页码。写入和构造过滤表达式时检查来源键只含字母、数字、`:`、`_`、`-`，通过检查后可以直接用单引号包住键值。

| 字段 | 类型 | 倒排索引 | 用途 |
|---|---|---|---|
| `embedding` | `VECTOR_FP32[dim]`，Flat，余弦 | — | 检索 |
| `source_key` | STRING | 有 | 按来源删除、清理 |
| `kind` | STRING | 有 | 范围预过滤 |
| `material_id` | STRING，可空 | 有 | 范围预过滤 |
| `conversation_id` | STRING，可空 | 有 | 范围预过滤 |
| `chunk` | INT64 | — | 片段序号 |
| `chunk_count` | INT64 | — | 只在 0 号片段上有意义，判断来源是否完整 |
| `source_version` | STRING | — | 与业务库比对 |
| `content` | STRING | — | 摘要与证据正文 |
| `locator_json` | STRING | — | 还原 `SemanticLocator` |
| `created_at` | STRING | — | 诊断 |

zvec 0.8.0 的 Dart 接口将 `Doc.setField` 收到的整数写为 INT64，因此片段序号和片段数使用 INT64。`model_key`、`dim` 与 `text_version` 写在状态文件里，每条文档据此关联同一个模型键。

### 4.4 操作对应

| `VectorIndex` 操作 | zvec 实现 |
|---|---|
| 打开 | isolate 入口在 `Zvec.isInitialized` 为假时调用 `Zvec.initialize`；`Collection.open`，目录不存在时 `createAndOpen`；被占用时退避重试 |
| `entryCount` | `collection.stats.docCount` |
| `indexedSources(keys)` | 按 500 个一批 `fetch(['<key>#0', …], outputFields: ['source_key', 'source_version', 'chunk_count'], includeVector: false)` |
| `sourceCount` | 读状态文件的 `source_count`，由刷新结束时写入 |
| `meta` / `setMeta` | 读写状态文件，只接受 `epoch`、`built_at`、`source_count` |
| `replaceSource` | 见 4.5；每批 `upsert` 检查 `WriteResult.errorCount` |
| `pruneSources(keep)` | `deleteByFilter("source_key not in (…)")`，返回删除前后 `docCount` 之差；`keep` 为空时整份清空 |
| `search(query, k, prefilter)` | 一次 `query`，`outputFields` 取齐 `StoredVector` 所需字段 |
| `clear` | 关闭 collection，目录改名后在原路径新建，再删除改名后的目录 |
| `close` | `flush` 后调用 `Collection.close()` 释放句柄 |

`indexedSources` 改成按键读取，是因为 zvec 的 Dart 包目前没有封装 C API 里的 `zvec_collection_create_iterator`，没有办法列出全部文档。按键读取反而更贴合刷新流程：`_runRefresh` 本来就先从业务库取到全部来源，再逐个比对，现在把这批键交给索引即可，不必把整个索引的清单读进内存。设置页显示的来源数改从 `sourceCount` 读。

`Collection.close()` 会释放原生句柄，`Collection.destroy()` 要求句柄仍有效，并会删除 collection 数据。对已经关闭的句柄调用 `destroy()` 会使进程崩溃，所以普通关闭只释放句柄，清空按表中的目录改名流程处理。引擎随进程退出回收，模型切换时继续供同一进程内的其他 isolate 使用，见 [zvec 0.8.0 collection 接口](https://github.com/alibaba/zvec/blob/v0.8.0/src/binding/c/c_api.cc)。

### 4.5 写入顺序与中途退出

zvec 的一次 `upsert` 只保证这一批文档本身，删除和写入之间没有事务。`replaceSource` 按下面的顺序执行，0 号片段最后写：

1. `upsert` 片段 1 至 n−1；
2. `deleteByFilter("source_key = '<key>' and chunk >= n")`，删掉旧版本多出来的片段；
3. `upsert` 0 号片段，带上新的 `source_version` 与 `chunk_count = n`。

只要第 3 步没有完成，0 号片段上仍是旧版本号，下一次刷新会认为这个来源需要重建，重新嵌入并覆盖。中途留下的新旧混合片段在检索时会被服务层的版本核对挡掉：`search` 已经用 `fresh.sourceVersion != candidate.sourceVersion` 排除过期候选，这一层不需要改。一个来源只有一个片段时，三步合成一次 `upsert`。

`flush` 在一次刷新结束时调用一次，不在每个来源后调用；WAL 已经保证进程崩溃时写入不丢，`flush` 只负责把内存中的段落盘。

### 4.6 范围预过滤

`search` 增加一个可选的预过滤参数，由服务层根据 `EvidenceScope` 生成。参数是一个值类型而不是表达式字符串，由各个索引实现自己解释，zvec 实现负责渲染成过滤表达式。过滤只使用写入后不会改变的属性：来源种类、材料页所属的 `material_id`、消息与作答所属的 `conversation_id`，以及来源键本身。讨论归属的目标可以在之后调整，写进索引会过期，所以目标范围不下推，仍由 `repository.inScope` 判断。

预过滤生成的是一个可能偏大的候选集，业务库核对仍然是最终判断。以材料范围为例，下推条件写成 `(kind = 'material_page' and material_id = 'X') or kind != 'material_page'`：其他材料的页面在索引内部就被排除，消息与作答仍按讨论归属交给业务库判断。材料页通常占索引的大头，排除之后 `limit × 20` 的放大可以降回 `limit × 4`，400 的上限也不再决定召回。回答前检索在没有目标归属时只看当前讨论与本轮带入的来源，可以写成 `conversation_id = 'C' or source_key in (…)`，与业务规则几乎重合。限定到目标时没有可下推的条件，保留现在的放大倍数。五种范围的完整对应与“预过滤只放宽”的性质测试见 [ADR-0022 实施方案第 5 节](adr/0022-语义索引改用zvec.md#5-范围预过滤)。

`StoredVector` 由一次 `query` 直接带回，不再逐条回表。服务层对每个候选调用 `repository.current` 的逐条核对仍然保留，这一步读的是业务库，不在本次替换的范围里。

### 4.7 后台线程与引擎参数

zvec 的写入是单进程独占，知新本来就只有一个后台 isolate 持有索引，这一点不需要调整。`Zvec.initialize` 传入 `ConfigData`：查询与 `optimize` 各用 1 个线程，避免和界面线程争用小核；内存上限设 256 MB，约合六万条 1024 维 FP32 向量的本体，原先是 128 MB，两万条时留给索引结构、写入缓冲与查询的余量不足；它仍是上限，不是常驻占用。引擎要求这个值大于 100 MB。日志写到缓存目录的文件里，级别为警告，原因见 ADR-0022 实施方案第 6 节。`Doc`、`VectorQuery` 持有原生内存，`ZvecVectorIndex` 内部用 `try/finally` 调用 `destroy`，不把它们传出 isolate；跨线程传递的仍是现在的 `Map` 与 `List`。

Flat 索引不需要 `optimize` 才能检索，但段数增加后检索会变慢。一次刷新写入超过 200 个文档时，在 `flush` 之后调用一次 `optimize` 合并段，两万条的耗时约 0.1 秒。

### 4.8 刷新时机与数据代次

刷新在四类事件之后执行：应用启动、来源表有净变化的提交之后等 3 秒、恢复或撤销或导入或清空之后、设置页手动更新。`GuardedDatabase` 在提交落库之后把改到的表交给应用根，应用根只对 `material_page`、`message`、`attempt` 三张表排刷新，连续提交共用一次扫描。

数据代次取 `HEAD` 所在提交的 `generation`，整版恢复、导入与清理历史各推进一次，普通写入沿用父提交的代次。代次与索引状态文件里的不同时，刷新先清空再重建；相同时按来源版本增量更新，删除的来源由 `pruneSources` 清理。代次随库保存，重启之后仍然一致。早先取的是 `HEAD` 本身，任何写入都会推进它，于是有写入之后的下一次刷新会整份重建，增量路径用不上；改成 `generation` 之后，普通写入只补变化的来源。

## 5. 依赖、构建与测试

`pubspec.yaml` 固定 `zvec: 0.8.0`（不写 `^`），旧引擎依赖已删除。`sqlite3` 与 `hooks` 一节保留，drift 与 FTS5 仍需要 Android 上随包的 SQLite；`hooks` 上方的注释说明 Android 随包是因为业务库，与语义索引无关。zvec 要求 Android API 28 与 arm64，[ADR-0003](adr/0003-最低系统版本与打包架构.md) 规定的是 API 30 与只出 `arm64-v8a`，两者一致。

zvec 的 Flutter 插件在 Gradle 的 `preBuild` 之前从 GitHub Releases 下载 C 库并校验 SHA-256，缓存目录由环境变量 `ZVEC_SDK_CACHE` 决定，默认是 `~/.cache/zvec-dart`（Windows 为 `%LOCALAPPDATA%\zvec-dart`）。`pubspec.yaml` 里的注释记录过 GitHub Releases 偶发 504，CI 的打包任务因此在 `actions/cache` 里加上这个目录，键取插件版本号。

测试分五类：

| 层 | 内容 | 运行条件 |
|---|---|---|
| 服务层 | `semantic_index_test.dart` 使用 `MemoryVectorIndex` | 任何环境 |
| 索引契约 | `vector_index_contract_test.dart`，同一组用例分别跑 `MemoryVectorIndex` 与 `ZvecVectorIndex`：写入、覆盖、缩短片段、清理、按键读取、过滤检索、中途退出后的版本判断、换模型重建 | `ZvecVectorIndex` 需要 `ZVEC_LIBRARY_PATH` 指向本机的 C 库，没有设置时跳过并打印原因 |
| isolate | `vector_store_isolate_test.dart`，覆盖后台 isolate 的打开、写入、查询、统计与两个 isolate 先后打开、关闭之后引擎仍可再用 | 同上 |
| 范围预过滤 | `vector_prefilter_test.dart`，`hitInScope` 判为在范围内的来源，预过滤必须放行 | 任何环境 |
| 刷新与代次 | `records_search_semantic_test.dart`：普通写入之后只补新来源、来源表提交之后按安静期补进索引；`guarded_database_test.dart`：净变化提交回调改到的表、空提交不回调 | 前者需要 `ZVEC_LIBRARY_PATH` 与真实 zvec，后者任何环境 |

CI 的 Linux 任务下载 `zvec-sdk-linux-amd64.tar.gz`（约 40 MB），按 `zvec_sdk.json` 里的 SHA-256 校验后放进缓存，再设置 `ZVEC_LIBRARY_PATH`。Windows 本机开发下载 `zvec-sdk-windows-amd64.zip` 后设置这个变量，步骤见 [app/README 的运行一节](../app/README.md#运行)。

## 6. 实施步骤

每一步单独提交，提交后 `flutter analyze` 与 `flutter test` 通过。六步已于 2026-11-16 全部完成。

1. **抽出接口。** `VectorIndex` 改成同步接口，原 SQLite 实现保留为过渡实现，新增 `MemoryVectorIndex`，服务层测试切换过去。行为不变。
2. **调整接口。** `indexedSources` 改为接受来源键，增加 `sourceCount`，`search` 增加过滤参数；`_runRefresh` 与 `stats()` 跟着改。
3. **实现 `ZvecVectorIndex`。** 加入依赖，写契约测试，CI 加缓存与 `ZVEC_LIBRARY_PATH`。
4. **切换运行时。** isolate 入口改为构造 `ZvecVectorIndex`，`AppPaths` 改目录，第一次打开时删除旧版索引文件。设置页的“重建索引”走一遍。
5. **范围预过滤。** 服务层由 `EvidenceScope` 生成过滤表达式，材料与讨论范围的候选放大倍数降到 `limit × 4`；召回是否不低于替换前待陈英硕用评测集复核，见第 8 节。
6. **收尾。** 删除过渡实现与旧引擎依赖，更新 [03 第 2.1 节的模块表](03-团队分工与协作.md#21-模块主责)、[app/README 的数据一节](../app/README.md#数据)与 `pubspec.yaml` 注释。

每一步的验收条件与负责人见 [ADR-0022 实施方案第 9 节](adr/0022-语义索引改用zvec.md#9-实施步骤与验收)。

## 7. 暂不纳入的能力

zvec 0.8 内置结巴分词的中文全文检索，可以在一次 `multiQuery` 里融合向量与关键词结果。关键词索引现在由业务库的触发器在同一个事务里维护，整版恢复和导入时由版本引擎重建（ADR-0013 第 6 条）；搬到 zvec 就要在两个存储之间自己保证一致，而且未配置嵌入模型的用户也要依赖 zvec。这一项等语义检索在内测中证明有用、再评估是否值得一并迁移。

HNSW 与量化在片段数超过十万之后再考虑。zvec 的 Dart 包补上文档迭代器后，`pruneSources` 可以改为遍历，不再拼接很长的 `not in` 列表；这一项可以给上游提交 PR，C API 已经具备。

## 8. 待定事项

| 事项 | 依据与现状 | 负责人 |
|---|---|---|
| 实施时机 | 已定：0.2.0 之前完成，M0 内落地，不再占 M1 与 M3 的待办 | 陈思源 |
| 范围预过滤后的召回是否不低于替换前 | 待陈英硕用评测集复核，结论未出 | 陈英硕 |
