import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../app_database.dart' show zhixinSchemaVersion;
import 'tables.dart';

part 'app_database.g.dart';

/// drift 版的本地库：表结构与索引来自 [tables.dart]，打开时建立外键与 WAL。
///
/// 结构变化仍按 ADR-0002 清空重建，不写迁移函数。采集暂存表与触发器由版本
/// 引擎在打开后安装，这里负责 28 张基础表与表类上声明的索引。
///
/// 仓库层的查询写在 `queries/` 下的 `.drift` 文件里，由 [include] 挂进来：
/// 表名、列名、参数与结果列的可空性在生成阶段检查（ADR-0011）。
@DriftDatabase(
  include: {
    'queries/assessments.drift',
    'queries/attempts.drift',
    'queries/conversations.drift',
    'queries/goals.drift',
    'queries/material_pages.drift',
    'queries/materials.drift',
    'queries/memories.drift',
    'queries/memory_usage.drift',
    'queries/messages.drift',
    'queries/plan_items.drift',
    'queries/schedules.drift',
    'queries/settings.drift',
    'queries/study_plans.drift',
    'queries/study_sessions.drift',
    'queries/timetable_entries.drift',
  },
  tables: [
    // 生成器的输入：`allTables` 与 `allSchemaEntities` 由这份清单与表类上的
    // `@TableIndex` 生成，运行时的结构校验都从生成结果读取，不再另抄清单。
    AppMeta,
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
    MemoryUsages,
    LocalMemoryUses,
    RevisionCommits,
    RevisionChanges,
    RevisionRefs,
    RevisionRefTombstones,
    RevisionCheckpoints,
    RevisionStates,
    RevisionCursors,
    RevisionAssetRefs,
    RevisionConflicts,
    SyncShadows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor) {
    openSites[this] = _callSite();
  }

  /// 测试与探针使用；真机由 `NativeDatabase(File)` 打开库文件。
  AppDatabase.memory() : super(NativeDatabase.memory()) {
    openSites[this] = _callSite();
  }

  @override
  Future<void> close() async {
    openSites.remove(this);
    await super.close();
  }

  @override
  int get schemaVersion => zhixinSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) => _rebuild(m),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );

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
  }
}

/// 只读取生成代码里表、列与索引定义的库实例，不打开连接。
///
/// drift 的结构元数据（`allTables` 与 `allSchemaEntities`）是实例成员，没有静态
/// 入口，恢复预检与版本引擎需要一个实例来读；这个子类的执行器在构造时不打开
/// 数据库，任何查询都会抛出。取用一律经 [schemaMetadata]，不再直接构造。
class SchemaMetadata extends AppDatabase {
  SchemaMetadata()
    : super(LazyDatabase(() => throw StateError('结构元数据不需要打开数据库')));
}

/// 结构元数据实例只建一次。
///
/// [AppDatabase] 每次构造都会让 drift 记一次“又开了一个库”；结构元数据按需多取
/// 几次并不等于开了第二个库，但会按 [AppDatabase] 这一类计数。只建一个并复用，
/// 计数才对应真实的连接。
final SchemaMetadata schemaMetadata = SchemaMetadata();

/// 还开着的库与它建出来的位置；库关掉时撤掉。
///
/// 同一个执行器上开两个库会抢同一组事务、写同一个库文件，drift 对此只在构造
/// 第二个同类库时打印告警，而它按运行时类型计数，把正常的多设备用例也算进去，
/// 告警因此对不上真实问题。这里按执行器记录，测试里由
/// `test/support/drift_warning_guard.dart` 检查并失败。
final Map<AppDatabase, String> openSites = {};

/// 库背后的执行器；[GeneratedDatabase.connection] 是 drift 给每个库各自包的
/// 一层，判断“同一个执行器上开了两个库”看的是 [GeneratedDatabase.executor]。
QueryExecutor driftExecutorOf(AppDatabase database) => database.executor;

/// 同时开着的库，结构元数据不计在内；先取快照，遍历时不受登记增减影响。
List<AppDatabase> get openDriftDatabases {
  final snapshot = [...openSites.keys];
  return [
    for (final database in snapshot)
      if (!identical(database, schemaMetadata)) database,
  ];
}

String _callSite() {
  for (final frame in StackTrace.current.toString().split('\n')) {
    if (!frame.contains('app/lib/') && !frame.contains('app/test/')) continue;
    final match = RegExp(r'\(([^()]+\.dart:\d+:\d+)\)$').firstMatch(frame);
    if (match != null) return match.group(1)!;
  }
  return '未知位置';
}
