# ADR-0012 结束 sqflite 与 drift 并存

## 状态

已采纳

## 日期

2026-11-14

## 背景

[ADR-0004](0004-数据层改用drift与自带sqlite.md) 把主库换成 drift 与随包 SQLite，理由是固定设备上的 SQLite 版本、取消系统库差异。主库已经按这个决定打开，但库副本的打开方式没有跟着换：`DataPackageService`、`StagedRestoreValidator` 与 `RevisionPackageService` 仍接收 sqflite 的 `DatabaseFactory`，用它打开数据包里的数据库与版本库快照，共 6 处 `factory.openDatabase`；`raw_executor.dart` 里还保留着 `SqfliteRawExecutor` 与两个扩展方法，40 个测试文件通过 `sqflite_common_ffi` 建库。同一份库文件因此在恢复路径上被另一套驱动打开，而这个驱动在 Android 上用的是系统 SQLite，ADR-0004 要消除的版本差异在恢复与打包路径上仍然存在。

评估见 [轮子与技术选型评估第 2.2 节](../轮子与技术选型评估.md#22-结束-sqflite-与-drift-并存)。

## 决定

1. 所有库副本改用 `package:sqlite3` 打开。备份、恢复校验与版本包只需要读或执行 `VACUUM INTO`，不需要 drift 的查询接口，因此新增一个统一的打开函数，直接把 `Database` 交给现有的执行器。
2. 执行器只留一个实现。`RawExecutor` 与 `RawDatabase` 的方法签名不变，`SqfliteRawExecutor`、`SqfliteRawDatabase` 与 `SqfliteExecutorRaw`、`SqfliteDatabaseRaw` 两个扩展删除，副本统一包装成经 `package:sqlite3` 执行的原生执行器。`raw_executor.dart` 不再导入 `package:sqflite`。
3. 备份、恢复校验与版本包的构造函数参数从 `DatabaseFactory factory` 改成可选的本机数据库路径与打开函数，调用方在 [app_scope.dart](../../app/lib/app_scope.dart) 装配处调整；三个服务的其余调用点与业务流程不变。
4. 文件型测试改用自己的 `sqlite3` 文件库与同一套打开函数，[test_db.dart](../../app/test/support/test_db.dart) 增加一个建文件库的入口；内存库继续用 `AppDatabase.memory()`。改动后测试不再需要 `sqfliteFfiInit`。
5. 从 `pubspec.yaml` 删除运行依赖 `sqflite` 与开发依赖 `sqflite_common_ffi`，同步清理 `app/pubspec.lock`。
6. 数据处置按 [ADR-0001](0001-开发阶段不向下兼容.md) 与 [ADR-0002](0002-本地数据不做迁移.md) 执行：库文件格式不变，schema 版本不提升，已装的开发包无需清空数据；旧版本导出的数据包只要 schema 版本相同仍然可以导入。

## 代价与边界

- 40 个测试文件要改导入与建库方式，其中一部分测试原来直接用 `databaseFactoryFfi.openDatabase` 检查库文件，这类地方改成 `sqlite3.open`。改动面集中在测试的建库准备上，断言与用例本身不动。
- `package:sqlite3` 在测试里走的是系统库，在 Android 上走随包库，两个环境对事务模式的支持相同，但 `VACUUM INTO` 与部分 `PRAGMA` 的行为要在模拟器上补一遍，与 ADR-0004 的验收范围一致。
- 随包库的路径由现有的构建钩子决定，删除 sqflite 不改变它；CI 的下载策略也不受影响。
- `sqflite` 删除之后，如果以后有插件间接依赖它，需要重新引入，届时要重新评估并存问题。
- `RawExecutor` 仍保留方法名沿用的 `query(table, where: ...)` 形态。这次不改造形状，因为 `schedule_conflicts.dart`、`settings_repository.dart`、`assessment_repository.dart` 与 `memory_repository.dart` 都按这个形状调用，混在一起改会让恢复路径的回归难以定位。

## 替代方案

- 继续让副本走 sqflite，只把主库固定在随包库上。没有采纳的原因是恢复路径仍会用系统 SQLite 解析同一份文件，触发器和部分索引在旧系统库上行为不同，恢复校验可能做出错误结论。
- 副本也用 drift 打开。没有采纳的原因是校验只需要几条 `PRAGMA` 与表结构查询，用 drift 要另建一份表结构或走 `NativeDatabase` 的完整初始化，比直接打开更重。
- 保留 `sqflite` 但只在测试里用。没有采纳的原因是运行期与测试期用两套驱动，CI 覆盖不到恢复路径真正使用的打开方式。

## 影响

- 数据层：[raw_executor.dart](../../app/lib/data/db/raw_executor.dart)、[data_package_service.dart](../../app/lib/data/backup/data_package_service.dart)、[restore_validation.dart](../../app/lib/data/backup/restore_validation.dart)、[revision_package.dart](../../app/lib/data/revisions/revision_package.dart)、[app_scope.dart](../../app/lib/app_scope.dart)。
- 依赖与测试：[app/pubspec.yaml](../../app/pubspec.yaml)、`app/test/` 下的 40 个测试文件与 [test_db.dart](../../app/test/support/test_db.dart)。
- 文档：[ADR-0004](0004-数据层改用drift与自带sqlite.md) 的收尾状态、[app/README 的数据一节](../../app/README.md)、[评估第 2.2 节](../轮子与技术选型评估.md#22-结束-sqflite-与-drift-并存)。
