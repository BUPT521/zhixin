// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

// 当前 schema 31 的 28 张表，结构唯一来源：建表、索引与文档比对都从这里派生。
//
// 表的 SQL 名称、列名、外键动作与主要约束写在这里，索引写在表类上的
// `@TableIndex`；采集暂存表与触发器由版本引擎安装，不在表类里声明。
//
// 业务表 14 张、设置表 1 张、记忆使用统计 1 张，其余 12 张是版本与同步的簿记。
// 这一版把同一事实只存一份：完整性只有整库摘要一个原语（ADR-0054 与审查 S1），
// 单行状态、`HEAD` 与提交编号合进 `revision_state`（S3、S14），截止小时并进
// `app_meta`（S4），计划当前页由步骤算出（S5）。

/// 不参与业务变更采集的版本元数据、同步元数据与附件对象表名前缀。
///
/// 新增这类表时沿用前缀即可，版本引擎按前缀把它归入元数据；其余新表默认
/// 参与采集，写入才会进入数据版本历史。同步元数据是同步过程的簿记，不是用户
/// 数据（ADR-0040），因此与版本元数据一样排除在采集、检查点投影与数据包之外。
const List<String> revisionMetadataTablePrefixes = [
  'revision_',
  'asset_',
  'sync_',
];

/// 保留在库里、但不参与版本采集的内部设置表。
const Set<String> nonVersionedPersistentTableNames = {'app_meta'};

// 列取值集合：表类的 CHECK 约束只引用这里的常量，值集合测试按表与列核对建库
// 结果。新增或删除取值只改这一处；模型枚举的文案与解码在 domain/models 各自
// 保留，这里只约束数据库接受的字符串。
//
// 常量必须是公开的：drift 生成代码（`app_database.g.dart`）会直接引用这些名字，
// 私有常量在生成文件里解析不到。

/// 学习目标与系统学习计划的状态取值。
const List<String> learningGoalStatuses = ['active', 'paused', 'done'];
const List<String> materialKinds = ['text', 'slides', 'book', 'other'];
const List<String> entryKinds = ['text', 'photo', 'text_photo'];
const List<String> conversationStatuses = ['open', 'ended'];
const List<String> messageRoles = ['user', 'assistant', 'system'];
const List<String> studyPlanStatuses = ['active', 'paused', 'done'];
const List<String> planItemStatuses = ['todo', 'doing', 'done', 'deferred'];

/// 事项与时间块的来源取值。
const List<String> sourceValues = ['user', 'ai'];
const List<String> scheduleBlockStatuses = ['planned', 'done', 'cancelled'];
const List<String> sessionOutcomes = ['done', 'partial', 'not_done'];
const List<String> assessmentKinds = ['model', 'user'];
const List<String> memoryKinds = ['episodic', 'semantic', 'procedural'];
const List<String> memorySourceKinds = [
  'user',
  'message',
  'attempt',
  'session',
];
const List<String> memoryStatuses = ['active', 'deleted'];

/// 记忆使用记录的种类：进入相关层、由 `search_memory` 读到。
const List<String> memoryUseKinds = ['recall', 'search'];
const List<String> revisionActors = ['user', 'ai', 'system'];
const List<String> changeOperations = ['insert', 'update', 'delete'];
const List<String> checkpointKinds = [
  'initial',
  'periodic',
  'trimmed',
  'named',
];

/// 提交类型：由写入路径决定，动作文案只给人看（[ADR-0039](../../../../../docs/adr/0039-数据版本的提交类型与同步冲突记录.md)）。
const List<String> revisionKinds = [
  'baseline',
  'write',
  'undo',
  'restore',
  'import',
  'maintenance',
  'remote',
];

/// 检查点投影的编码：只有 `json+gzip` 一种（ADR-0054 实施前核对删去了 `json`）。
const List<String> checkpointEncodings = ['json+gzip'];

/// 命名版本的同步状态：干净表示与云端一致，已改表示本机改过、还没推送。
const List<String> revisionRefSyncStates = ['clean', 'dirty'];

/// 附件引用的主人：一次提交的变更明细，或者一份检查点。
const List<String> revisionAssetOwnerKinds = ['change', 'checkpoint'];

/// 远端提交覆盖本机修改时记下的冲突原因。
const List<String> revisionConflictReasons = [
  'concurrent_update',
  'deleted_locally',
  'insert_collision',
  'deleted_remotely_modified',
];

/// 各列允许的取值集合；键是“表名.列名”。
const Map<String, List<String>> checkValueSets = {
  'learning_goal.status': learningGoalStatuses,
  'material.kind': materialKinds,
  'conversation.entry_kind': entryKinds,
  'conversation.status': conversationStatuses,
  'message.role': messageRoles,
  'study_plan.status': studyPlanStatuses,
  'plan_item.status': planItemStatuses,
  'plan_item.source': sourceValues,
  'schedule_block.source': sourceValues,
  'schedule_block.status': scheduleBlockStatuses,
  'study_session.outcome': sessionOutcomes,
  'assessment.kind': assessmentKinds,
  'memory.kind': memoryKinds,
  'memory.source_kind': memorySourceKinds,
  'memory.status': memoryStatuses,
  'memory_use.kind': memoryUseKinds,
  'revision_commit.actor': revisionActors,
  'revision_commit.kind': revisionKinds,
  'revision_change.op': changeOperations,
  'revision_checkpoint.kind': checkpointKinds,
  'revision_checkpoint.encoding': checkpointEncodings,
  'revision_asset_ref.owner_kind': revisionAssetOwnerKinds,
  'revision_conflict.reason': revisionConflictReasons,
  'revision_ref.sync_state': revisionRefSyncStates,
};

@DataClassName('AppMetaRow')
class AppMeta extends Table {
  @override
  String get tableName => 'app_meta';
  TextColumn get key => text()();
  TextColumn get value => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('LearningGoalRow')
class LearningGoals extends Table {
  @override
  String get tableName => 'learning_goal';
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get scopeText => text().nullable()();
  TextColumn get dueDate => text().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant('active'))
      .check(status.isIn(learningGoalStatuses))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AssetObjectRow')
class AssetObjects extends Table {
  @override
  String get tableName => 'asset_object';
  TextColumn get hash => text()();
  IntColumn get byteLength =>
      integer().check(byteLength.isBiggerOrEqualValue(0))();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {hash};
}

@TableIndex(name: 'idx_asset_chunk_hash', columns: {#hash, #seq})
@DataClassName('AssetChunkRow')
class AssetChunks extends Table {
  @override
  String get tableName => 'asset_chunk';
  TextColumn get hash =>
      text().references(AssetObjects, #hash, onDelete: KeyAction.cascade)();
  IntColumn get seq => integer().check(seq.isBiggerOrEqualValue(0))();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {hash, seq};
}

@TableIndex(name: 'idx_material_goal', columns: {#goalId})
@DataClassName('MaterialRow')
class Materials extends Table {
  @override
  String get tableName => 'material';
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get kind => text()
      .withDefault(const Constant('text'))
      .check(kind.isIn(materialKinds))();
  TextColumn get sourceRef => text().nullable()();
  TextColumn get sourceFileName => text().nullable()();
  TextColumn get sourceFileHash =>
      text().nullable().references(AssetObjects, #hash)();
  TextColumn get goalId => text().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<String> get customConstraints => const [
    'CHECK ((source_file_name IS NULL) = (source_file_hash IS NULL))',
  ];

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_material_page_material', columns: {#materialId, #pageNo})
@DataClassName('MaterialPageRow')
class MaterialPages extends Table {
  @override
  String get tableName => 'material_page';
  TextColumn get id => text()();
  TextColumn get materialId =>
      text().references(Materials, #id, onDelete: KeyAction.cascade)();
  IntColumn get pageNo => integer().check(pageNo.isBiggerThanValue(0))();
  TextColumn get label => text().nullable()();
  TextColumn get content => text()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {materialId, pageNo},
  ];

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_conversation_status', columns: {#status, #updatedAt})
@TableIndex(name: 'idx_conversation_goal', columns: {#goalId})
@TableIndex(name: 'idx_conversation_material', columns: {#materialId})
@DataClassName('ConversationRow')
class Conversations extends Table {
  @override
  String get tableName => 'conversation';
  TextColumn get id => text()();
  TextColumn get title => text().nullable()();
  TextColumn get goalId => text().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get materialId => text().nullable().references(
    Materials,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get pageNo => integer().nullable()();
  TextColumn get sourceRef => text().nullable()();
  TextColumn get contextText => text().nullable()();
  TextColumn get questionMessageId => text().nullable()();
  TextColumn get entryKind => text()
      .withDefault(const Constant('text'))
      .check(entryKind.isIn(entryKinds))();
  TextColumn get status => text()
      .withDefault(const Constant('open'))
      .check(status.isIn(conversationStatuses))();
  TextColumn get endedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_message_conversation',
  columns: {#conversationId, #createdAt},
)
@DataClassName('MessageRow')
class Messages extends Table {
  @override
  String get tableName => 'message';
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text().check(role.isIn(messageRoles))();
  TextColumn get content => text()();
  TextColumn get imagePathsJson => text().nullable()();
  TextColumn get structuredJson => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_study_plan_material', columns: {#materialId, #status})
@DataClassName('StudyPlanRow')
class StudyPlans extends Table {
  @override
  String get tableName => 'study_plan';
  TextColumn get id => text()();
  TextColumn get materialId => text().nullable().references(
    Materials,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get goalId => text().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get conversationId => text().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get title => text()();
  IntColumn get pageFrom => integer().nullable()();
  IntColumn get pageTo => integer().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant('active'))
      .check(status.isIn(studyPlanStatuses))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_plan_item_status_due', columns: {#status, #dueAt})
@TableIndex(name: 'idx_plan_item_goal', columns: {#goalId})
@TableIndex(name: 'idx_plan_item_conversation', columns: {#conversationId})
@TableIndex(
  name: 'idx_plan_item_study_seq',
  columns: {#studyPlanId, #seq},
  unique: true,
)
@DataClassName('PlanItemRow')
class PlanItems extends Table {
  @override
  String get tableName => 'plan_item';
  TextColumn get id => text()();
  TextColumn get goalId => text().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get conversationId => text().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get studyPlanId => text().nullable().references(
    StudyPlans,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get seq =>
      integer().nullable().check(seq.isNull() | seq.isBiggerThanValue(0))();
  TextColumn get title => text()();
  TextColumn get note => text().nullable()();
  IntColumn get pageFrom => integer().nullable().check(
    pageFrom.isNull() | pageFrom.isBiggerThanValue(0),
  )();
  IntColumn get pageTo => integer().nullable().check(
    pageTo.isNull() | pageTo.isBiggerThanValue(0),
  )();
  TextColumn get dueAt => text().nullable()();
  IntColumn get estMinutes => integer().nullable().check(
    estMinutes.isNull() | estMinutes.isBetweenValues(5, 240),
  )();
  IntColumn get priority => integer()
      .withDefault(const Constant(0))
      .check(priority.isBetweenValues(0, 2))();
  TextColumn get status => text()
      .withDefault(const Constant('todo'))
      .check(status.isIn(planItemStatuses))();
  TextColumn get source => text()
      .withDefault(const Constant('user'))
      .check(source.isIn(sourceValues))();
  TextColumn get originJson => text().nullable()();
  TextColumn get completedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TimetableEntryRow')
class TimetableEntries extends Table {
  @override
  String get tableName => 'timetable_entry';
  TextColumn get id => text()();
  IntColumn get weekday => integer().check(weekday.isBetweenValues(1, 7))();
  TextColumn get startTime => text()();
  TextColumn get endTime => text()();
  TextColumn get title => text()();
  TextColumn get location => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<String> get customConstraints => const ['CHECK (end_time > start_time)'];

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_schedule_start', columns: {#startAt})
@TableIndex(name: 'idx_schedule_plan', columns: {#planItemId})
@DataClassName('ScheduleBlockRow')
class ScheduleBlocks extends Table {
  @override
  String get tableName => 'schedule_block';
  TextColumn get id => text()();
  TextColumn get planItemId =>
      text().references(PlanItems, #id, onDelete: KeyAction.cascade)();
  TextColumn get startAt => text()();
  TextColumn get endAt => text()();
  TextColumn get source => text()
      .withDefault(const Constant('user'))
      .check(source.isIn(sourceValues))();
  TextColumn get status => text()
      .withDefault(const Constant('planned'))
      .check(status.isIn(scheduleBlockStatuses))();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<String> get customConstraints => const ['CHECK (end_at > start_at)'];

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_session_plan', columns: {#planItemId, #startedAt})
@TableIndex(
  name: 'idx_session_conversation',
  columns: {#conversationId, #endedAt},
)
@DataClassName('StudySessionRow')
class StudySessions extends Table {
  @override
  String get tableName => 'study_session';
  TextColumn get id => text()();
  TextColumn get goalId => text().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get planItemId => text().nullable().references(
    PlanItems,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get conversationId => text().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get summary => text().nullable()();
  TextColumn get outcome =>
      text().nullable().check(outcome.isIn(sessionOutcomes))();
  TextColumn get startedAt => text()();
  TextColumn get endedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_attempt_conversation',
  columns: {#conversationId, #submittedAt},
)
@TableIndex(name: 'idx_attempt_session', columns: {#sessionId})
@TableIndex(name: 'idx_attempt_redo', columns: {#redoOfAttemptId})
@DataClassName('AttemptRow')
class Attempts extends Table {
  @override
  String get tableName => 'attempt';
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get sessionId => text().nullable().references(
    StudySessions,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get redoOfAttemptId => text().nullable().references(
    Attempts,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get userAnswer => text().nullable()();
  TextColumn get solution => text().nullable()();
  BoolColumn get isCorrect => boolean().nullable()();
  BoolColumn get independent => boolean().nullable()();
  BoolColumn get delayed => boolean().withDefault(const Constant(false))();
  TextColumn get helpJson => text().nullable()();
  TextColumn get feedback => text().nullable()();
  TextColumn get submittedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_assessment_attempt', columns: {#attemptId, #kind})
@DataClassName('AssessmentRow')
class Assessments extends Table {
  @override
  String get tableName => 'assessment';
  TextColumn get id => text()();
  TextColumn get attemptId =>
      text().references(Attempts, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind => text().check(kind.isIn(assessmentKinds))();
  TextColumn get result => text()();
  TextColumn get basis => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_memory_status', columns: {#status, #kind})
@TableIndex(name: 'idx_memory_valid', columns: {#validUntil})
@DataClassName('MemoryRow')
class Memories extends Table {
  @override
  String get tableName => 'memory';
  TextColumn get id => text()();

  /// 情景、语义、程序三类（ADR-0051）；旧的四类标签由回复注入口径取代。
  TextColumn get kind => text().check(kind.isIn(memoryKinds))();
  TextColumn get content => text()();
  TextColumn get scope => text().nullable()();
  TextColumn get sourceKind =>
      text().check(sourceKind.isIn(memorySourceKinds))();
  TextColumn get sourceId => text().nullable()();
  TextColumn get validUntil => text().nullable()();

  /// 写入时由模型顺带给出的检索线索，几条短语用换行分隔，空串表示没有；
  /// 只进全文索引，不在界面显示（ADR-0051 决定第 7 条）。
  TextColumn get searchTerms => text().withDefault(const Constant(''))();

  /// 用户确认保留的时间；写这一列不连带更新 [updatedAt]（ADR-0051 决定第 9 条）。
  TextColumn get reviewedAt => text().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant('active'))
      .check(status.isIn(memoryStatuses))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 记忆的使用统计（ADR-0051 决定第 8 条）。
///
/// 一行是某条记忆在某台设备的计数与时间，设备编号取自 ADR-0048；每台设备只写
/// 自己的行，汇总时计数相加、时间取最大值，因此不产生同步冲突。
///
/// 计数由本机已导出到使用记录表的时间点现算（召回、读出、使用、确认保留各记
/// 一条），[FirstSeenAt] 记本机最早看到这条时间点的时刻，远端提交带来其他设备
/// 的更早时间点时把它前移；下一次冲刷只数 [FirstSeenAt] 之后的时间点，重复
/// 冲刷不重复累加。主键是单列 [Id]，按“记忆编号＋设备编号”的唯一约束定位行：
/// 版本引擎的采集只支持单列主键，复合主键的稳定行键由这一列承担。
@TableIndex(
  name: 'idx_memory_usage_memory_device',
  columns: {#memoryId, #deviceId},
  unique: true,
)
@DataClassName('MemoryUsageRow')
class MemoryUsages extends Table {
  @override
  String get tableName => 'memory_usage';
  TextColumn get id => text()();
  TextColumn get memoryId =>
      text().references(Memories, #id, onDelete: KeyAction.cascade)();
  TextColumn get deviceId => text()();
  IntColumn get recallCount => integer().withDefault(const Constant(0))();
  IntColumn get searchCount => integer().withDefault(const Constant(0))();
  TextColumn get lastRecalledAt => text().nullable()();
  TextColumn get lastSearchedAt => text().nullable()();
  TextColumn get firstSeenAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 记忆被召回与读出的时间点，一台设备一行、只增不改。
///
/// 一行是“某台设备在某个时刻把某条记忆放进了相关层（或由 `search_memory` 读
/// 到）”，正文只是时间与记忆编号，由使用统计现算计数，因此不需要计数器与去重
/// 列；每行带 [acquiredAt] 记本机拿到它的时刻，远端提交同样带上，远端行落在
/// 更大的值上时按后写覆盖，两端取较大值。旧行由使用统计在冲刷时清理（ADR-0051 决定第 8 条）。
@TableIndex(name: 'idx_memory_use_memory', columns: {#memoryId, #usedAt})
@TableIndex(name: 'idx_memory_use_device', columns: {#deviceId, #usedAt})
@DataClassName('MemoryUseRow')
class MemoryUses extends Table {
  @override
  String get tableName => 'memory_use';
  TextColumn get id => text()();
  TextColumn get memoryId =>
      text().references(Memories, #id, onDelete: KeyAction.cascade)();
  TextColumn get deviceId => text()();

  /// `recall` 表示进入相关层，`search` 表示由 `search_memory` 读到。
  TextColumn get kind => text()
      .withDefault(const Constant('recall'))
      .check(kind.isIn(memoryUseKinds))();
  TextColumn get usedAt => text()();
  TextColumn get acquiredAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_revision_uid', columns: {#uid}, unique: true)
@TableIndex(name: 'idx_revision_commit_parent', columns: {#parentId})
@TableIndex(name: 'idx_revision_commit_reverted', columns: {#revertedCommitId})
@DataClassName('RevisionCommitRow')
class RevisionCommits extends Table {
  @override
  String get tableName => 'revision_commit';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get parentId => integer().nullable().references(
    RevisionCommits,
    #id,
    onDelete: KeyAction.setNull,
  )();

  IntColumn get generation => integer()();

  /// 这条提交落库之后全部业务行的一致性摘要；完整性只认这一个原语，变更明细
  /// 的条数与冲突条数在读取时现数（ADR-0054 与审查 S1）。
  TextColumn get stateDigest => text()();
  TextColumn get actor => text().check(actor.isIn(revisionActors))();

  /// 提交类型：`baseline`、`write`、`undo`、`restore`、`import`、
  /// `maintenance`、`remote`；界面按它显示标签与图标，不再从 [action] 推断。
  TextColumn get kind => text().check(kind.isIn(revisionKinds))();

  /// 提交身份：全局唯一、永不复用，推送与服务端去重、远端提交的本机去重都按它。
  ///
  /// 本机提交由界面在用户动作开始时生成 UUIDv7 并一路传下来，远端提交沿用远端
  /// 的 uid；不按提交编号或动作参数派生（ADR-0053 决定第 3 条）。
  TextColumn get uid => text()();

  /// 给人看的动作说明；不参与撤销与界面类型的判断。
  TextColumn get action => text()();
  IntColumn get restoredCommitId => integer().nullable()();
  IntColumn get revertedCommitId => integer().nullable()();

  /// 这条提交变更明细的字节数；按容量裁剪用它估算每条提交占用的空间。
  IntColumn get byteLength => integer()
      .withDefault(const Constant(0))
      .check(byteLength.isBiggerOrEqualValue(0))();

  TextColumn get createdAt => text()();

  /// 远端提交由服务端带来的设备标识；本机提交为空（方案 3.12）。
  TextColumn get originDevice => text().nullable()();

  /// 远端提交的作者创建时间；本机提交为空，界面回退到 [createdAt]（方案 3.12）。
  TextColumn get authoredAt => text().nullable()();

  /// 这条提交在服务端序列上的序号：远端提交取拉取到的值，本机提交推送成功之后
  /// 取推送响应里的逐条序号。空值只表示还不知道它排在第几条，不影响同步
  /// （ADR-0054 决定第 2 条）。
  IntColumn get serverSeq => integer().nullable()();
}

@TableIndex(
  name: 'idx_revision_change_target',
  columns: {#targetTable, #rowKey},
)
@TableIndex(name: 'idx_revision_change_commit', columns: {#commitId, #seq})
@DataClassName('RevisionChangeRow')
class RevisionChanges extends Table {
  @override
  String get tableName => 'revision_change';
  IntColumn get commitId =>
      integer().references(RevisionCommits, #id, onDelete: KeyAction.cascade)();
  IntColumn get seq => integer()();
  TextColumn get targetTable => text().named('table_name')();
  TextColumn get rowKey => text()();
  TextColumn get op => text().check(op.isIn(changeOperations))();
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {commitId, seq};
}

/// 用户给版本起的名字（01 `revision_ref`）。
///
/// 只存命名版本，`HEAD` 在 [RevisionStates] 的 `head_commit_id` 里；指向的提交按
/// `revision_commit.uid` 查，查不到就是“只剩标签”的名字（ADR-0054 决定第 4 条）。
@TableIndex(name: 'idx_revision_ref_uid', columns: {#commitUid})
@DataClassName('RevisionRefRow')
class RevisionRefs extends Table {
  @override
  String get tableName => 'revision_ref';

  /// 名字先做 NFC 规范化再写入，主键按规范化之后的名字比较。
  TextColumn get name => text()();
  TextColumn get commitUid => text()();

  /// 干净表示与云端一致，已改表示本机改过、还没推送。
  TextColumn get syncState => text()
      .withDefault(const Constant('clean'))
      .check(syncState.isIn(revisionRefSyncStates))();
  TextColumn get note => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {name};
}

/// 用户显式删除一个名字之后留下的墓碑，推送成功之后删行（ADR-0054 决定第 4 条）。
///
/// 清理本机历史、清除全部数据与恢复备份都不写墓碑；表名沿用 `revision_` 前缀，
/// 不参与版本采集。
@DataClassName('RevisionRefTombstoneRow')
class RevisionRefTombstones extends Table {
  @override
  String get tableName => 'revision_ref_tombstone';
  TextColumn get name => text()();
  TextColumn get deletedAt => text()();

  @override
  Set<Column> get primaryKey => {name};
}

@TableIndex(name: 'idx_revision_checkpoint_commit', columns: {#commitId, #id})
@DataClassName('RevisionCheckpointRow')
class RevisionCheckpoints extends Table {
  @override
  String get tableName => 'revision_checkpoint';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => text().check(kind.isIn(checkpointKinds))();
  IntColumn get commitId => integer()();

  /// 业务投影的字节，gzip 压缩之后的检查点原文；解出 JSON 再还原投影。
  BlobColumn get payload => blob()();
  TextColumn get encoding => text().check(encoding.isIn(checkpointEncodings))();

  /// 压缩之前的字节数，用于留存统计与按容量裁剪的估算。
  IntColumn get rawBytes => integer().check(rawBytes.isBiggerOrEqualValue(0))();

  /// 这份投影的一致性摘要；重建之后可以直接与当前表比对（方案 3.5）。
  TextColumn get stateDigest => text()();
  TextColumn get createdAt => text()();
}

/// 历史的下游读者在库里登记读到哪里。
///
/// 会丢数据的读者（同步推送）把 [blocking] 置 1，裁剪与清理历史不能越过它的
/// [position]；只会退回全量重建的读者（文本索引、记忆索引）不阻止裁剪。
@DataClassName('RevisionCursorRow')
class RevisionCursors extends Table {
  @override
  String get tableName => 'revision_cursor';
  TextColumn get name => text()();
  IntColumn get position => integer()();
  BoolColumn get blocking => boolean().withDefault(const Constant(false))();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {name};
}

/// 提交与检查点引用的附件对象；附件回收与核对读这张表，不再解码全部变更明细。
@TableIndex(name: 'idx_revision_asset_hash', columns: {#hash})
@DataClassName('RevisionAssetRefRow')
class RevisionAssetRefs extends Table {
  @override
  String get tableName => 'revision_asset_ref';

  /// `change` 表示一次提交的变更明细，`checkpoint` 表示一份检查点的附件清单。
  TextColumn get ownerKind =>
      text().check(ownerKind.isIn(revisionAssetOwnerKinds))();
  IntColumn get ownerId => integer()();
  TextColumn get hash => text()();

  @override
  Set<Column> get primaryKey => {ownerKind, ownerId, hash};
}

/// 应用远端提交时被覆盖的本机修改。
///
/// 同步仍然是后到覆盖先到；这张表让本机能列出每一处被覆盖的本机值，并把本机
/// 值作为一条普通提交写回（`keepLocal`）。
@DataClassName('RevisionConflictRow')
class RevisionConflicts extends Table {
  @override
  String get tableName => 'revision_conflict';
  IntColumn get id => integer().autoIncrement()();

  /// 应用远端提交时在本机形成的 `remote` 提交。
  IntColumn get commitId =>
      integer().references(RevisionCommits, #id, onDelete: KeyAction.cascade)();
  TextColumn get targetTable => text().named('table_name')();
  TextColumn get rowKey => text()();

  /// 整行冲突（新增撞上同一主键）时为空。
  TextColumn get columnName => text().nullable()();
  TextColumn get reason => text().check(reason.isIn(revisionConflictReasons))();
  TextColumn get localJson => text()();
  TextColumn get remoteBeforeJson => text().nullable()();
  TextColumn get remoteAfterJson => text()();

  /// 本机值已经写回时，指回那条 `write` 提交。
  IntColumn get resolvedCommitId => integer().nullable()();
}

/// 已被远端提交取代的本机格子：推送时按格变基，去掉这些格子再推（ADR-0040）。
///
/// 同步的簿记表，不参与版本采集、检查点投影与数据包（表名前缀 `sync_`）。
/// `upto_commit` 是应用这条远端提交之前的本机 `HEAD`，含义是编号不大于它的
/// 本机提交在这个格子上的改动作废。[columnName] 用空字符串表示整行变化：
/// SQLite 的唯一约束认为两个 NULL 互不相同，用空字符串才能让整行遮蔽与列级
/// 遮蔽一样每个格子只留一行。
@DataClassName('SyncShadowRow')
class SyncShadows extends Table {
  @override
  String get tableName => 'sync_shadow';
  TextColumn get targetTable => text().named('table_name')();
  TextColumn get rowKey => text()();
  TextColumn get columnName => text()();
  IntColumn get uptoCommit => integer()();

  @override
  Set<Column> get primaryKey => {targetTable, rowKey, columnName};
}

/// 版本引擎的单行状态：采集上下文、提交编号与 `HEAD`（ADR-0054 决定第 4 条）。
///
/// 这一行在 `installRevisionSchema` 里创建，早于编号为 0 的基线提交，所以
/// [headCommitId] 不设外键、默认指向基线提交；[tableDigestsJson] 只在 `HEAD`
/// 上保存各业务表的分表摘要，每条提交仍只存总摘要。
@DataClassName('RevisionStateRow')
class RevisionStates extends Table {
  @override
  String get tableName => 'revision_state';
  IntColumn get id => integer().check(id.equals(1))();

  /// 已经预留、还没有落库的提交编号；没有预留时为空。
  IntColumn get activeCommit => integer().nullable()();

  /// 触发器按它判断这次命令是否要采集行变化；命令开始时置 1，结束时清 0。
  BoolColumn get capturing => boolean().withDefault(const Constant(false))();

  /// 整版恢复与导入期间暂停采集，避免把整库删除与重插记成逐行历史。
  BoolColumn get suppress => boolean().withDefault(const Constant(false))();

  /// 下一个要分配的提交编号；只增不减。
  IntColumn get nextCommit => integer()();

  /// `HEAD` 指向的提交编号。
  IntColumn get headCommitId => integer()
      .withDefault(const Constant(0))
      .check(headCommitId.isBiggerOrEqualValue(0))();

  /// `HEAD` 上各业务表的一致性摘要，表名到 64 位十六进制值的 JSON 映射；各表
  /// 值之和恒等于 `HEAD` 提交的 `state_digest`（ADR-0054 决定第 1 条）。
  TextColumn get tableDigestsJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {id};
}
