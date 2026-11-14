# ADR-0004 数据层改用 drift 与自带 SQLite

## 状态

已采纳。查询侧的编译期检查、库副本的打开方式与 sqflite 的移除由 [ADR-0011](0011-仓库查询改用drift生成代码.md) 与 [ADR-0012](0012-结束sqflite与drift并存.md) 接续，本条原文保持当时的样子。

## 日期

2026-11-13

## 背景

本地库现在由 sqflite 打开，用的是 Android 系统自带的 SQLite。API 30 上的系统库是 3.28，没有 trigram 分词器，SQLite 小版本也随设备变化。业务表 23 张、178 列，仓库层有约 4,800 行手写 SQL，写入要经过 `GuardedDatabase` 自动开一次提交，版本引擎再用触发器采集净变化。开发期数据可以丢弃，库结构不承诺兼容（[ADR-0002](0002-本地数据不做迁移.md)）。

团队希望表结构与查询在编译期就被检查，写入路径只留一个入口，设备上的 SQLite 版本固定。试算过代码体量：按仓库 DDL 生成 4 张表、42 列，drift 2.28 在关闭 manager 时生成 2,523 行，默认配置生成 3,843 行；按 23 张表、178 列外推，生成量约 1.1 万至 1.9 万行。代码总量会变大，换取的是类型检查与统一的执行器，这个取舍已经确认。

向量索引已经通过 `sqlite3` 包与 hooks 配置随包携带预编译库，主库改用同一份库不会额外增加原生库，只会多出 drift 的 Dart 代码与 `build_runner` 的开发依赖。

## 决定

用 `drift` 2.35 系列与 `NativeDatabase` 打开现有的 `zhixin.db`，SQLite 由 `sqlite3` 包随包提供，不再使用 Android 系统库。schema 版本保持 26：SQLite 文件格式不变，旧库可以直接被自带库打开；如果 P0 对照发现 drift 生成的表结构与现有 DDL 在约束、部分索引上有无法接受的差异，再按 [ADR-0002](0002-本地数据不做迁移.md) 升版本并清空重建，不写迁移函数。

23 张表用 drift 表类定义，数据类统一加 `Row` 后缀，避免与领域模型重名。建表由 drift 的 `createAll` 负责；27 个索引（含部分索引）、采集暂存表与触发器仍由版本引擎用原生 SQL 安装。恢复校验用的表名与必需列改成从 drift 的 `allTables` 派生，删除 `schema.dart` 里的重复清单。生成文件提交入库，`build_runner` 配置关闭 `generate_manager`，CI 在格式检查之前重新生成并核对没有差异。

写入仍是本次改动的核心。原来的 `GuardedDatabase` 同时负责读共享写独占、独立写入自动提交、拒绝 `REPLACE`；改用 drift 后，写入统一经 `WriteTransactions` 建立 drift 事务，由版本引擎的 `beginCommand` 建提交、`finishCommand` 收尾，仓库的写方法只接收 `WriteTx`，不接收整个连接。`REPLACE` 由 `WriteTx` 不提供该模式来禁止。读路径拿 `AppDatabase`，只用查询。版本引擎、备份与恢复校验的 4,000 多行原生 SQL 不改写成 DSL，通过一个 `RawSql` 适配器落在 drift 的 `customSelect` 与 `customStatement` 上。

恢复沿用“独占区内换库”的流程。`AppDatabase` 绑定执行器，不能直接替换文件，因此在它下面放一个可替换的 `QueryExecutor`：独占时关闭旧执行器、替换库文件、打开新文件，`AppDatabase` 与仓库实例保持不变。P0 先验证换执行器之后查询、事务与流查询都正常；如果 drift 的内部状态不允许这样换，就把 `AppScope` 里 `late final` 的服务改成可重建，恢复后重建依赖图，代价是页面状态要重新装配。

## 代价与边界

- 生成代码约 1.1 万至 1.9 万行，写入仓库并进入每次 schema 改动的 diff；构建多一步 codegen，CI 多一步重生成核对。
- 数据层约 8,000 行手写代码要重写，76 个测试文件、约 2.1 万行测试要改建库方式与查询写法；版本、撤销、恢复与附件校验的回归风险最高。
- 执行器替换依赖 drift 的内部行为，P0 不能通过时改走重建依赖图，恢复之后页面状态与进行中的操作要重新装配。
- 自带库固定了 SQLite 版本，设备上不再有系统库差异；CI 主机的系统库版本仍与设备不同，涉及 `RETURNING`、部分索引与触发器的测试要在模拟器上补一遍。
- 不承诺旧库兼容。本次不额外写迁移；打开时版本或结构不一致的库按现行规则重建，旧数据包在恢复入口拒绝。

## 替代方案

- 继续用 sqflite，只把新查询写成 drift。没有采纳的原因是两套执行器并存，写入要同时维护代理与 drift 两条路径，版本引擎的事务边界更难看懂。
- 用 drift 但仍打开 Android 系统 SQLite。没有采纳的原因是系统库版本随设备变化，trigram 与 `RETURNING` 仍不可用，换 drift 的主要收益少了一半。
- 换成 Isar 或 ObjectBox。没有采纳的原因是它们没有现成的行级变更历史、检查点与撤销语义，版本引擎要整体重写。
- 版本引擎也改写成 drift DSL。没有采纳的原因是引擎依赖动态触发器、`PRAGMA` 与按表合并净变化，DSL 表达不了，改写的收益只是形式统一。

## 影响

- 依赖与构建：[app/pubspec.yaml](../../app/pubspec.yaml)、[ci.yml](../../.github/workflows/ci.yml)。
- 数据层：[app_database.dart](../../app/lib/data/db/app_database.dart)、[guarded_database.dart](../../app/lib/data/db/guarded_database.dart)、[schema.dart](../../app/lib/data/db/schema.dart)、[schema_objects.dart](../../app/lib/data/db/schema_objects.dart)、[revision_engine.dart](../../app/lib/data/revisions/revision_engine.dart)、[app_scope.dart](../../app/lib/app_scope.dart)。
- 测试：`app/test/` 下的建库 helper 与全部仓库测试。
- 文档：[01 第 7 章](../01-ER数据模型.md#7-导出恢复与版本)、[app/README 数据与目录](../../app/README.md)、[README 技术栈](../../README.md)。
