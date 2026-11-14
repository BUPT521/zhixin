import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../app_database.dart' show zhixinSchemaVersion;
import '../schema.dart' show schemaIndexStatements;
import 'tables.dart';

part 'app_database.g.dart';

/// drift 版的本地库：表结构来自 [tables.dart]，打开时建立外键与 WAL。
///
/// 结构变化仍按 ADR-0002 清空重建，不写迁移函数。采集暂存表、索引与触发器
/// 由版本引擎在打开后安装，这里只负责 23 张基础表。
///
/// 仓库层的查询写在 `queries/` 下的 `.drift` 文件里，由 [include] 挂进来：
/// 表名、列名、参数与结果列的可空性在生成阶段检查（ADR-0011）。
@DriftDatabase(
  include: {
    'queries/schedule_conflicts.drift',
    'queries/study_plans.drift',
    'queries/tasks.drift',
  },
  tables: [
    AppMeta,
    Profiles,
    LearningGoals,
    AssetObjects,
    AssetChunks,
    Materials,
    MaterialPages,
    Conversations,
    Messages,
    StudyPlans,
    PlanItems,
    TimetableEntries,
    ScheduleBlocks,
    StudySessions,
    Attempts,
    Assessments,
    Memories,
    RevisionCommits,
    RevisionChanges,
    RevisionRefs,
    RevisionCheckpoints,
    RevisionContexts,
    RevisionSequences,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// 测试与探针使用；真机由 `NativeDatabase(File)` 打开库文件。
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => zhixinSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (m, from, to) => _rebuild(m),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );

  /// 业务索引不在 drift 表类里声明，建表之后按旧 DDL 的清单补齐。
  Future<void> _createIndexes() async {
    for (final statement in schemaIndexStatements()) {
      await customStatement(statement);
    }
  }

  /// 清空所有表并按当前结构重建；外键在删除期间延迟检查。
  Future<void> _rebuild(Migrator m) async {
    await customStatement('PRAGMA defer_foreign_keys = ON');
    final rows = await customSelect(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    for (final row in rows.reversed) {
      final name = row.data['name']! as String;
      await customStatement('DROP TABLE IF EXISTS "$name"');
    }
    await m.createAll();
    await _createIndexes();
  }
}
