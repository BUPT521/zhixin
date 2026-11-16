# 知新 · 语义索引接入 zvec 的方案

> 本文给出把语义索引的存储引擎从 `sqlite3_vec` 换成 [zvec](https://github.com/alibaba/zvec) 的做法：改哪一层、数据怎样落盘、每个操作怎样对应、构建与测试怎样调整，以及按什么顺序实施。范围是 2026-11-16 `main` 上的 `app/lib/data/vector/` 与 `semantic_index_service.dart`；关键词检索、业务库与服务端不在范围内。决定本身记在 [ADR-0022](adr/0022-语义索引改用zvec.md)（提议），本文是它的实施说明。

## 1. 结论

替换只发生在 `VectorStore` 接口以下。`SemanticIndexService`、证据检索与界面继续通过 `VectorStore` 读写，后台 isolate 的消息协议保留，换掉的是 isolate 里实际持有数据的那一层：现在的 `VectorIndex` 用一个 SQLite 文件同时存放元数据表 `vector_entry` 和 `vec0` 虚拟表，接入后改为一个 zvec collection 加一个状态文件。接口的调整集中在几处：`indexedSources` 改为按调用方给出的来源键读取，新增 `sourceCount`，`search` 增加一个范围预过滤参数，`pruneSources` 改为返回删除的向量条数，完整清单见 [ADR-0022 实施方案第 1 节](adr/0022-语义索引改用zvec.md#1-接口改动)。打开与关闭的顺序、损坏后的处理、发布与回退也记在 ADR-0022 的实施方案里，本文不重复。

索引类型用 Flat（精确检索）与余弦距离，不做量化。每个嵌入模型一个 collection 目录，模型、维度或文本处理版本改变时换目录、删旧目录。zvec 没有跨文档事务，`replaceSource` 先写其余片段、最后写 0 号片段，0 号片段承担提交记录的作用，中途退出时下一次刷新会把这个来源判为“需要重建”。关键词检索继续使用 [ADR-0013](adr/0013-关键词检索改用FTS5.md) 的 FTS5。

这次替换的收益主要来自检索路径。zvec 在一次调用里完成范围过滤并返回片段正文，因此可以省去逐条回表，减少材料或讨论范围的检索候选数，过渡期结束后也可去掉 `sqlite3_vec` 构建钩子对 clang 工具链的依赖。主要代价是安装包，arm64 release APK 会存放未压缩的原生库，包体实测见 [ADR-0022 代价与边界](adr/0022-语义索引改用zvec.md#代价与边界)。

现有的 `sqlite3_vec`（内置 sqlite-vec 0.1.9）也支持 `vec0` 元数据列与辅助列，知新现在的表只建了向量列，两条路线的差别见第 3.1 节。第 6 节的第 2、3 步对两条路线都适用，采用哪条路线由第 1 步的真机性能数据决定。

## 2. 现状

| 文件 | 职责 |
|---|---|
| [vector_store.dart](../app/lib/data/vector/vector_store.dart) | `VectorStore` 接口；`DirectVectorStore` 在同一线程里直接调用 `VectorIndex`，只用于测试 |
| [vector_store_isolate.dart](../app/lib/data/vector/vector_store_isolate.dart) | `IsolateVectorStore`：后台 isolate 持有索引，界面线程按操作名发送请求，`_runOperation` 分派 |
| [vector_index.dart](../app/lib/data/vector/vector_index.dart) | `VectorIndex`：SQLite 文件 `vector_index.db`，`vector_index_meta` 存键值，`vector_entry` 存片段与来源信息，`vec_rows_<dim>` 是 `vec0` 虚拟表 |
| [semantic_index_service.dart](../app/lib/application/semantic_index_service.dart) | 刷新（比对来源版本、嵌入、写入、清理）与检索（取候选、逐条核对业务记录与范围） |
| [app_paths.dart](../app/lib/platform/app_paths.dart) | `vectorIndexPath` 指向 `filesDir/vector_index.db` |

检索时 `VectorIndex.search` 先从 `vec0` 取 k 个 rowid，再对每个 rowid 查一次 `vector_entry`；服务层随后对每个候选调用 `repository.current` 与 `repository.inScope` 核对。现在的 `vec0` 表只建了向量列，检索时不知道范围，限定到某个目标或材料时，范围外的向量会挤占候选，所以服务层把候选数放大到 `limit × 20` 并封顶 400，范围很窄时仍可能漏召回。

## 3. 测得的数据

数据来自本机沙箱（x86_64，2 核），zvec 用 PyPI 上的 0.8.1，`sqlite-vec` 用 PyPI 上的 0.1.9。Dart SDK 与 Python 包调用的是同一个 C 引擎，绝对数值在 PLK110 上会不同，比例可以参考。向量为 1024 维（`embedding_config_store.dart` 的默认维度），每个来源 4 个片段，共 20000 个片段，约相当于 640 万字正文。

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

## 4. 目标结构

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

`VectorIndex` 从具体类改成同步接口，原来的 SQLite 实现在最后一步删除。`MemoryVectorIndex` 用 Dart 列表做余弦距离排序，替代测试里的 `VectorIndex.open(inMemory: true)`，这样服务层的 17 个用例不依赖任何原生库。

### 4.2 磁盘布局

```
filesDir/vector_index/
  <model_key 的短哈希>/        # 一个 zvec collection
  <model_key 的短哈希>.json    # model_key、dim、text_version、epoch、built_at、source_count
```

`AppPaths.vectorIndexPath` 改为指向 `vector_index/` 目录。每个 collection 配一个同名的状态文件，模型在两个键之间来回切换时，新旧 isolate 各写各的文件。当前模型的 collection 打开成功之后，再删除其他模型键的目录与状态文件，删除的时机与失败时的处理见 [ADR-0022 实施方案第 2 节](adr/0022-语义索引改用zvec.md#2-打开关闭与并发)。旧版的 `vector_index.db`、`-wal`、`-shm` 在同一步删除；按 [ADR-0002](adr/0002-本地数据不做迁移.md)，语义索引本来就是可以从业务库重建的派生数据，不做迁移，内测用户已有索引时的例外见 ADR-0022 实施方案第 7 节。

状态文件用“写临时文件、再改名”的方式原子替换。它只在打开、清空和一次刷新结束时写入，不随每个来源写。

### 4.3 文档结构

主键是 `<source_key>#<chunk>`。`source_key` 的格式是 `种类:UUID`，写入前断言它只含字母、数字、`:`、`_`、`-`，这样过滤表达式里直接用单引号包住即可，不需要转义规则。

| 字段 | 类型 | 倒排索引 | 用途 |
|---|---|---|---|
| `embedding` | `VECTOR_FP32[dim]`，Flat，余弦 | — | 检索 |
| `source_key` | STRING | 有 | 按来源删除、清理 |
| `kind` | STRING | 有 | 范围预过滤 |
| `material_id` | STRING，可空 | 有 | 范围预过滤 |
| `conversation_id` | STRING，可空 | 有 | 范围预过滤 |
| `chunk` | INT32 | — | 片段序号 |
| `chunk_count` | INT32 | — | 只在 0 号片段上有意义，判断来源是否完整 |
| `source_version` | STRING | — | 与业务库比对 |
| `content` | STRING | — | 摘要与证据正文 |
| `locator_json` | STRING | — | 还原 `SemanticLocator` |
| `created_at` | STRING | — | 诊断 |

`model_id` 与 `text_version` 不再逐条保存，因为一个 collection 只对应一个模型键。

### 4.4 操作对应

| `VectorIndex` 操作 | zvec 实现 |
|---|---|
| 打开 | isolate 入口在 `Zvec.isInitialized` 为假时调用 `Zvec.initialize`；`Collection.open`，目录不存在时 `createAndOpen`；被占用时退避重试 |
| `entryCount` | `collection.stats.docCount` |
| `indexedSources(keys)` | 按 500 个一批 `fetch(['<key>#0', …], outputFields: ['source_version', 'chunk_count'], includeVector: false)` |
| `sourceCount` | 读状态文件的 `source_count`，由刷新结束时写入 |
| `meta` / `setMeta` | 读写状态文件，只接受 `epoch`、`built_at`、`source_count` |
| `replaceSource` | 见 4.5；每批 `upsert` 检查 `WriteResult.errorCount` |
| `pruneSources(keep)` | `deleteByFilter("source_key not in (…)")`，返回删除前后 `docCount` 之差；`keep` 为空时整份清空 |
| `search(query, k, prefilter)` | 一次 `query`，`outputFields` 取齐 `StoredVector` 所需字段 |
| `clear` | 关闭 collection，目录改名后在原路径新建，再删除改名后的目录 |
| `close` | `flush`、`close`、`destroy`；不调用 `Zvec.shutdown`，引擎是进程级的，模型切换时可能还有另一个 isolate 在用 |

`indexedSources` 改成按键读取，是因为 zvec 的 Dart 包目前没有封装 C API 里的 `zvec_collection_create_iterator`，没有办法列出全部文档。按键读取反而更贴合刷新流程：`_runRefresh` 本来就先从业务库取到全部来源，再逐个比对，现在把这批键交给索引即可，不必把整个索引的清单读进内存。设置页显示的来源数改从 `sourceCount` 读。

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

zvec 的写入是单进程独占，知新本来就只有一个后台 isolate 持有索引，这一点不需要调整。`Zvec.initialize` 传入 `ConfigData`：查询与 `optimize` 各用 1 个线程，避免和界面线程争用小核；内存上限设 128 MB，引擎要求这个值大于 100 MB，PLK110 实测后再调。日志写到缓存目录的文件里，级别为警告，原因见 ADR-0022 实施方案第 6 节。`Doc`、`VectorQuery` 持有原生内存，`ZvecVectorIndex` 内部用 `try/finally` 调用 `destroy`，不把它们传出 isolate；跨线程传递的仍是现在的 `Map` 与 `List`。

Flat 索引不需要 `optimize` 才能检索，但段数增加后检索会变慢。一次刷新写入超过 200 个文档时，在 `flush` 之后调用一次 `optimize` 合并段，两万条的耗时约 0.1 秒。

## 5. 依赖、构建与测试

`pubspec.yaml` 增加 `zvec: 0.8.0`（固定版本，不写 `^`），过渡期结束后删除 `sqlite3_vec`。`sqlite3` 与 `hooks` 一节保留，drift 与 FTS5 仍需要 Android 上随包的 SQLite；`hooks` 上方的注释改为说明 Android 随包是因为业务库，不再提语义索引。zvec 要求 Android API 28 与 arm64，[ADR-0003](adr/0003-最低系统版本与打包架构.md) 规定的是 API 30 与只出 `arm64-v8a`，两者一致。

zvec 的 Flutter 插件在 Gradle 的 `preBuild` 之前从 GitHub Releases 下载 C 库并校验 SHA-256，缓存目录由环境变量 `ZVEC_SDK_CACHE` 决定，默认是 `~/.cache/zvec-dart`（Windows 为 `%LOCALAPPDATA%\zvec-dart`）。`pubspec.yaml` 里的注释记录过 GitHub Releases 偶发 504，CI 的打包任务因此在 `actions/cache` 里加上这个目录，键取插件版本号。

测试分两层：

| 层 | 内容 | 运行条件 |
|---|---|---|
| 服务层 | `semantic_index_test.dart` 改用 `MemoryVectorIndex` | 任何环境 |
| 索引契约 | 新增 `vector_index_contract.dart`，同一组用例分别跑 `MemoryVectorIndex` 与 `ZvecVectorIndex`：写入、覆盖、缩短片段、清理、按键读取、过滤检索、中途退出后的版本判断、换模型重建 | `ZvecVectorIndex` 需要 `ZVEC_LIBRARY_PATH` 指向本机的 C 库，没有设置时跳过并打印原因 |
| isolate | `vector_store_isolate_test.dart` 保留，换成 zvec 实现 | 同上 |

CI 的 Linux 任务下载 `zvec-sdk-linux-amd64.tar.gz`（约 40 MB），按 `zvec_sdk.json` 里的 SHA-256 校验后放进缓存，再设置 `ZVEC_LIBRARY_PATH`。Windows 本机开发同样下载 `zvec-sdk-windows-amd64.zip` 后设置这个变量。沙箱里不再需要为 `sqlite3_vec` 的构建钩子准备 clang 的替身脚本。

## 6. 实施步骤

每一步单独提交，提交后 `flutter analyze` 与 `flutter test` 通过。

1. **真机验证（不进 `main`）。** 在单独分支只加 `zvec` 依赖，打一个 release APK，记录与 `main` 的包体差；在 PLK110 上用 2000 与 20000 条 1024 维向量测打开、写入、检索与 `optimize` 的耗时。数据写进 ADR-0022 的“代价与边界”，再决定是否继续。
2. **抽出接口。** `VectorIndex` 改成同步接口，原 SQLite 实现改名为 `SqliteVectorIndex`，新增 `MemoryVectorIndex`，服务层测试切换过去。行为不变。
3. **调整接口。** `indexedSources` 改为接受来源键，增加 `sourceCount`，`search` 增加过滤参数；`SqliteVectorIndex` 对过滤参数直接忽略，`_runRefresh` 与 `stats()` 跟着改。
4. **实现 `ZvecVectorIndex`。** 加入依赖，写契约测试，CI 加缓存与 `ZVEC_LIBRARY_PATH`。
5. **切换运行时。** isolate 入口改为构造 `ZvecVectorIndex`，`AppPaths` 改目录，第一次打开时删除旧的 `vector_index.db*`。设置页的“重建索引”在真机上走一遍。
6. **范围预过滤。** 服务层由 `EvidenceScope` 生成过滤表达式，材料与讨论范围的候选放大倍数降到 `limit × 4`，用陈英硕的检索评测集比对替换前后的前几条结果。
7. **收尾。** 删除 `SqliteVectorIndex` 与 `sqlite3_vec`，更新 [03 第 2.1 节的模块表](03-团队分工与协作.md#21-模块主责)、[app/README 的数据一节](../app/README.md#数据)与 `pubspec.yaml` 注释，ADR-0022 改为已采纳。

第 2、3 步不依赖 zvec，即使第 1 步的结论是不替换，也可以单独合入：接口按键读取与范围参数对现在的实现同样成立。每一步的验收条件、负责人与第 1 步的继续门槛见 [ADR-0022 实施方案第 9 节](adr/0022-语义索引改用zvec.md#9-实施步骤与验收)。

## 7. 暂不纳入的能力

zvec 0.8 内置结巴分词的中文全文检索，可以在一次 `multiQuery` 里融合向量与关键词结果。关键词索引现在由业务库的触发器在同一个事务里维护，整版恢复和导入时由版本引擎重建（ADR-0013 第 6 条）；搬到 zvec 就要在两个存储之间自己保证一致，而且未配置嵌入模型的用户也要依赖 zvec。这一项等语义检索在内测中证明有用、再评估是否值得一并迁移。

HNSW 与量化在片段数超过十万之后再考虑，届时用第 1 步的真机数据重新比较 `optimize` 的耗时。zvec 的 Dart 包补上文档迭代器后，`pruneSources` 可以改为遍历，不再拼接很长的 `not in` 列表；这一项可以给上游提交 PR，C API 已经具备。

## 8. 待定事项

| 事项 | 需要的依据 | 负责人 |
|---|---|---|
| 接 zvec，还是改造 `vec0` 的表结构（第 3.1 节） | 第 1 步的真机性能数据对照 ADR-0022 第 9 节的门槛 | 陈思源 |
| 是否在 M1 内实施，还是排到 M3 | [04 长期路线图](04-长期路线图.md) 中 M1 的剩余工作量 | 陈思源 |
| 范围预过滤后的召回是否不低于现在 | 第 6 步的评测对比 | 陈英硕 |
