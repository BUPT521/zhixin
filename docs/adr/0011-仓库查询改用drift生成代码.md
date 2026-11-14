# ADR-0011 仓库查询改用 drift 生成代码

## 状态

已采纳。实施按“决定”第 3 条分两批进行，每一批单独提交。

## 日期

2026-11-14

## 背景

[ADR-0004](0004-数据层改用drift与自带sqlite.md) 用 drift 与随包 SQLite 换掉了 sqflite，目标是“表结构与查询在编译期就被检查”，并明确版本引擎、备份与恢复校验的原生 SQL 不改写成 DSL。主库换成 drift 之后，表结构这一半做到了，查询这一半没有：`lib/data/repository/` 下的 12 个仓库文件全部经 `DriftRawDatabase` 调用字符串 SQL，仓库层共有 50 处 `rawQuery`、1 处 `rawInsert`、1 处 `rawUpdate` 与 1 处 `rawDelete`，`customSelect` 与 `.watch` 没有一处使用；行数据靠 94 处 `fromRow` 与约 510 处 `as String`、`as int?` 一类强制转换还原成领域模型。列名拼错、可空性写错或者参数顺序颠倒，只有在跑到那条查询时才会暴露，而 drift 已经付出的代价是约 1.2 万行生成代码。

评估见 [轮子与技术选型评估第 2.1 节](../轮子与技术选型评估.md#21-仓库查询改用-drift-文件生成)。

## 决定

1. 仓库层的查询写进 `.drift` 文件，不改成 Dart DSL。现有 SQL 原样放入 `app/lib/data/repository` 之外的一个目录（建议 `app/lib/data/db/drift/queries/`），一条语句一个名字，按所属仓库分文件；drift 在 `build_runner` 阶段解析每条语句，校验表名、列名、参数个数与结果列的类型和可空性，生成带类型的查询方法与结果类。
2. 仓库对外的方法签名不变，内部改为调用生成的方法并做两次映射：生成的参数类由领域模型或调用方传入的值填充，生成的结果行映射成现有领域模型。领域模型的 `fromRow` 保留，但只在结果行与领域模型字段不同名或需要解析派生值时使用，不再逐列写 `as 类型`。
3. 分两批迁移。第一批是检索仓库以外的读方法，包括 `schedule_conflicts.dart`、`study_plan_repository.dart` 与 `task_repository.dart` 里按周、按状态取行的查询，这一批不碰写入路径，先证明生成代码与现有查询的结果一致；第二批覆盖其余仓库的读写方法与跨表事务，按仓库逐个搬。`evidence_repository.dart` 的关键词查询依赖动态拼接的 `LIKE`，它的迁移排在 [ADR-0013](0013-关键词检索改用FTS5.md) 之后，同样归入第二批。
4. 写入路径保留现有结构：仓库写方法仍只接收 `WriteTx` 或者经 `GuardedDatabase` 的命令事务进入，drift 只负责生成语句，不接管事务边界。跨表事务（`conversation_repository.dart`、`material_repository.dart`、`schedule_repository.dart`、`study_plan_repository.dart` 里的 14 处 `_db.transaction`）继续由 `GuardedDatabase.transaction` 独占执行，事务内需要查或改的表由生成代码的事务伴侣完成，不新开连接，也不绕过 `DatabaseGate`。
5. 版本引擎、备份、恢复校验、撤销与向量索引的原生 SQL 不动。这些代码依赖动态表名、`PRAGMA`、触发器和按表遍历，生成器表达不了，仍按 ADR-0004 留在 `RawSql` 适配器上。
6. 生成文件与现有 `app_database.g.dart` 一样提交入库，CI 在格式检查之前重新生成并核对没有差异。

## 代价与边界

- 仓库层与对应测试都要改。第一批动到 `schedule_conflicts.dart`、`study_plan_repository.dart`、`task_repository.dart` 与迁移后引用它们的测试文件，第二批覆盖剩下 9 个仓库文件与其余测试。迁移期间两批并存，同一张表可能同时存在手写 SQL 与生成查询，直到对应的仓库文件完成迁移。
- 每条查询多一层参数类与结果行的映射代码，仓库文件的行数会增加；换来的是编译期检查与后续流式查询的入口。
- `.drift` 文件改了必须重新生成，生成量随仓库查询数量增加；`build_runner` 的耗时与 CI 的重生成核对步骤都会变长。
- 动态拼接的查询，例如检索时按词数拼出的 `LIKE ? OR LIKE ?`，不能原样放进 `.drift` 文件。检索仓库的这类查询按 [ADR-0013](0013-关键词检索改用FTS5.md) 改写成 FTS5 的 `MATCH`，在检索仓库排进第二批之前保持手写；其余无法改写的查询留在适配器上，并在文件里注明原因。
- 生成查询的类型推断以 drift 为准。SQLite 的动态类型会让 `SUM`、`MAX` 一类聚合在生成结果里变成可空，遇到与现有手工转换不一致时修正领域模型，不为迁就旧写着保留手工转换。
- 内测开始后如果表结构冻结，`.drift` 文件的改动与生成代码的差量仍按同一流程提交，冻结只限制表结构与 SQLite 结构。

## 替代方案

- 在 `RawDatabase` 上手工包一层类型转换，或者写脚本按列名生成 `fromRow`。没有采纳的原因是列名的正确性仍靠运行期查错，参数个数与可空性也检查不到，换取的只是少写几百行转换代码。
- 把查询改写成 drift 的 Dart DSL。ADR-0004 已经否掉过，理由是团队要保留可读的原生 SQL，而且改写本身带来的差异比类型检查的收益更大。
- 换成 `sqfentity`、`floor` 一类能在编译期检查的 ORM。没有采纳的原因是生成体量与 drift 相当，但都不支持原生 SQL 与现有触发器、`PRAGMA` 混用，迁移面更大。

## 影响

- 数据层：[app_database.dart](../../app/lib/data/db/drift/app_database.dart)、[drift_raw.dart](../../app/lib/data/db/drift/drift_raw.dart)、[guarded_database.dart](../../app/lib/data/db/guarded_database.dart) 与 `app/lib/data/repository/` 下的仓库文件。
- 构建配置：[app/pubspec.yaml](../../app/pubspec.yaml) 的 `build_runner` 段落、[ci.yml](../../.github/workflows/ci.yml) 的重生成核对。
- 测试：`app/test/` 下引用仓库方法的测试与 [test_db.dart](../../app/test/support/test_db.dart)。
- 文档：[01 第 6 章](../01-ER数据模型.md#6-索引与典型查询)、[app/README 的数据一节](../../app/README.md)、[评估第 2.1 节](../轮子与技术选型评估.md#21-仓库查询改用-drift-文件生成)。
