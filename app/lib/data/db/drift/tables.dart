// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

// 当前 schema 32 的 28 张表，结构唯一来源：建表、索引与文档比对都从这里派生。
//
// 表的 SQL 名称、列名、外键动作与主要约束写在这里，索引写在表类上的
// `@TableIndex`；采集暂存表与触发器由版本引擎安装，不在表类里声明。
//
// 业务表 13 张、设置表 1 张、记忆使用统计 2 张，其余 12 张是版本、附件与同步的
// 簿记。
// 这一版把表结构的形状收口到索引与约束上：记忆召回先记在本机缓冲表、不参与
// 采集，附件引用列与列组显式声明，跨列 CHECK 只约束总是一起写入的列（ADR-0051、
// 0054，审查第 9 节）。完整性仍只有整库摘要一个原语。

/// 不参与业务变更采集的版本元数据、同步元数据、附件对象与本机缓冲表名前缀。
///
/// 新增这类表时沿用前缀即可，版本引擎按前缀把它归入元数据；其余新表默认
/// 参与采集，写入才会进入数据版本历史。同步元数据是同步过程的簿记，不是用户
/// 数据（ADR-0040），本机缓冲表（`local_memory_use`）记的是还没有汇总进统计的
/// 召回，同样不是用户数据（审查 S16），因此一并排除在采集、检查点投影与数据包
/// 之外。
const List<String> revisionMetadataTablePrefixes = [
  'revision_',
  'asset_',
  'sync_',
  'local_',
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
///
/// `kind` 只表示这条提交做了什么，来源只看 `origin_device`；远端提交沿用它在
/// 原来设备上的类型（审查 S23）。
const List<String> revisionKinds = [
  'baseline',
  'write',
  'undo',
  'restore',
  'import',
  'maintenance',
];

/// 命名版本的同步状态：干净表示与云端一致，已改表示本机改过、还没推送。
const List<String> revisionRefSyncStates = ['clean', 'dirty'];

/// 附件引用的主人：一次提交的变更明细，或者一份检查点。
const List<String> revisionAssetOwnerKinds = ['change', 'checkpoint'];

/// 远端提交覆盖本机修改时记下的冲突原因。
///
/// `unique_key_taken` 表示远端插入的行与另一条本机行撞上有含义的唯一键（目前是
/// `material_page(material_id, page_no)`），这一行跳过不写，由数据版本页提示
/// 用户处理（审查 S18）。
const List<String> revisionConflictReasons = [
  'concurrent_update',
  'deleted_locally',
  'insert_collision',
  'deleted_remotely_modified',
  'unique_key_taken',
];

/// 各列允许的取值集合；键是“表名.列名”。
const Map<String, List<String>> checkValueSets = {
  'learning_goal.status': learningGoalStatuses,
  'material.kind': materialKinds,
  'conversation.entry_kind': entryKinds,
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
  'local_memory_use.kind': memoryUseKinds,
  'revision_commit.actor': revisionActors,
  'revision_commit.kind': revisionKinds,
  'revision_change.op': changeOperations,
  'revision_checkpoint.kind': checkpointKinds,
  'revision_asset_ref.owner_kind': revisionAssetOwnerKinds,
  'revision_conflict.reason': revisionConflictReasons,
  'revision_ref.sync_state': revisionRefSyncStates,
};

/// 附件引用列：键是“表名.列名”，值表示这一列存一个哈希还是哈希组成的 JSON 数组。
///
/// 附件回收、导出核对与版本明细的引用收集只读这里声明的列。以前的做法是扫描
/// 每个文本列，凡是 64 位十六进制就当成附件哈希，`memory_usage.id` 这种恰好是
/// 这种形状的编号会被误当成缺失的附件（审查 S17）。
enum AttachmentReferenceKind { hash, hashArray }

const Map<String, AttachmentReferenceKind> attachmentReferenceColumns = {
  'material.source_file_hash': AttachmentReferenceKind.hash,
  'message.image_hashes_json': AttachmentReferenceKind.hashArray,
};

/// 采集与远端应用时整组写入的列组：键是“表名.列名”。
///
/// 组里任一列变化时，采集把整组列写进变更明细，远端应用时也整组写入；跨列
/// CHECK 因此只约束总是一起写入的列，本机改一列、远端改另一列时合并出来的行
/// 不会违反约束（审查 S18）。
const List<List<String>> revisionColumnGroups = [
  ['timetable_entry.start_time', 'timetable_entry.end_time'],
  ['schedule_block.start_at', 'schedule_block.end_at'],
  ['material.source_file_name', 'material.source_file_hash'],
];

/// 远端应用时撞上非主键唯一约束的两种处置（审查 S18）。
enum RevisionUniqueKeyPolicy {
  /// 只表示顺序的列：把本机行改到下一个空号，远端这一行照常写入。
  renumberLocal,

  /// 有含义的唯一键：跳过远端这一行，记一条 `unique_key_taken` 冲突。
  skipRemote,
}

/// 会让远端提交在本机撞上非主键唯一约束的列与处置方式。
///
/// 列的顺序就是唯一约束的列顺序；[RevisionUniqueKeyPolicy.renumberLocal] 改的
/// 是最后一列（步骤序号）。表上还有唯一约束没登记时不会检查，撞上会抛约束错误
/// 并让整条远端提交回滚，所以新增唯一索引时要在这里补一行（审查 S18）。
class RevisionUniqueKey {
  const RevisionUniqueKey(this.table, this.columns, this.policy);

  final String table;
  final List<String> columns;
  final RevisionUniqueKeyPolicy policy;
}

const List<RevisionUniqueKey> revisionUniqueKeys = [
  RevisionUniqueKey('plan_item', [
    'study_plan_id',
    'seq',
  ], RevisionUniqueKeyPolicy.renumberLocal),
  RevisionUniqueKey('material_page', [
    'material_id',
    'page_no',
  ], RevisionUniqueKeyPolicy.skipRemote),
  RevisionUniqueKey('memory_usage', [
    'memory_id',
    'device_id',
  ], RevisionUniqueKeyPolicy.skipRemote),
];

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
@TableIndex(name: 'idx_material_source_file_hash', columns: {#sourceFileHash})
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

@TableIndex(name: 'idx_conversation_updated', columns: {#updatedAt})
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

  /// 图片的附件哈希数组；列名写的是哈希，不是路径（审查 S17）。
  TextColumn get imageHashesJson => text().nullable()();
  TextColumn get structuredJson => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_study_plan_material', columns: {#materialId, #status})
@TableIndex(name: 'idx_study_plan_goal', columns: {#goalId})
@TableIndex(name: 'idx_study_plan_conversation', columns: {#conversationId})
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
@TableIndex(name: 'idx_session_goal', columns: {#goalId})
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
@DataClassName('MemoryRow')
class Memories extends Table {
  @override
  String get tableName => 'memory';
  TextColumn get id => text()();

  /// 情景、语义、程序三类（ADR-0051）；旧的四类标签由回复注入口径取代。
  TextColumn get kind => text().check(kind.isIn(memoryKinds))();

  /// 正文允许 Markdown 与多句条件，表的长度上限 2000 字；写入上限在召回预算
  /// 做出来之前仍是 200 字，见 `memoryContentLimit`（ADR-0051 决定第 6 条）。
  TextColumn get content =>
      text().check(CustomExpression<bool>('length(content) <= 2000'))();
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

/// 记忆的使用统计（ADR-0051 决定第 8 条，审查 S16）。
///
/// 一行是某条记忆在某台设备的计数与最近使用时间，设备编号取自 ADR-0048；每台
/// 设备只写自己的行，汇总时计数相加、时间取最大值，因此不产生同步冲突。
///
/// 计数先记在本机缓冲表 [LocalMemoryUses]，由冲刷在一条 `maintenance` 提交里
/// 汇总进来，所以这里没有水位列。主键是单列 [id]，按“记忆编号＋设备编号”的
/// 唯一约束定位行：版本引擎的采集只支持单列主键，复合主键的稳定行键由这一列
/// 承担；编号按 ADR-0053 用 UUIDv5 从设备编号与记忆编号生成，不再是内容哈希的
/// 形状（审查 S17）。
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
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 记忆被召回与读出的本机缓冲，只在本机累积、不参与采集与同步。
///
/// 一行是“某一刻把某条记忆放进了相关层（或由 `search_memory` 读到）”，只保存
/// 记忆编号、种类与时刻；冲刷在同一条 `maintenance` 提交里把行汇总进
/// [MemoryUsages] 再删除缓冲行，汇总与删除在同一个事务里，所以不再需要水位，
/// 也没有设备编号与取得时刻两列（审查 S16）。表名前缀 `local_` 让它不参与
/// 采集、检查点投影与数据包。
@TableIndex(name: 'idx_local_memory_use_memory', columns: {#memoryId})
@DataClassName('LocalMemoryUseRow')
class LocalMemoryUses extends Table {
  @override
  String get tableName => 'local_memory_use';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get memoryId =>
      text().references(Memories, #id, onDelete: KeyAction.cascade)();

  /// `recall` 表示进入相关层，`search` 表示由 `search_memory` 读到。
  TextColumn get kind => text()
      .withDefault(const Constant('recall'))
      .check(kind.isIn(memoryUseKinds))();
  TextColumn get usedAt => text()();

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

  /// 提交编号：基线为 0，其余由 `revision_state.next_commit` 预留，两处插入都
  /// 显式给出，不用 `AUTOINCREMENT` 另维护一份 `sqlite_sequence`（审查 S22）。
  IntColumn get id => integer()();
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

  /// 提交类型：`baseline`、`write`、`undo`、`restore`、`import`、`maintenance`；
  /// 界面按它显示标签与图标，不再从 [action] 推断。来源是另一台设备还是本机，
  /// 只看 [originDevice]，与类型无关（审查 S23）。
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

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_revision_change_target',
  columns: {#targetTable, #rowKey},
)
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
@TableIndex(name: 'idx_revision_conflict_commit', columns: {#commitId})
@DataClassName('RevisionConflictRow')
class RevisionConflicts extends Table {
  @override
  String get tableName => 'revision_conflict';
  IntColumn get id => integer().autoIncrement()();

  /// 应用远端提交时在本机形成的提交，类型沿用远端那条提交的 `kind`。
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
