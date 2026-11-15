// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

// 当前 schema 26 的 23 张表，结构唯一来源：建表、索引与文档比对都从这里派生。
//
// 表的 SQL 名称、列名、外键动作与主要约束写在这里，索引写在表类上的
// `@TableIndex`；采集暂存表与触发器由版本引擎安装，不在表类里声明。

/// 不参与业务变更采集的版本元数据与附件对象表名前缀。
///
/// 新增这类表时沿用前缀即可，版本引擎按前缀把它归入元数据；其余新表默认
/// 参与采集，写入才会进入数据版本历史。
const List<String> revisionMetadataTablePrefixes = ['revision_', 'asset_'];

/// 保留在库里、但不参与版本采集的内部设置表。
const Set<String> nonVersionedPersistentTableNames = {'app_meta'};
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

@DataClassName('ProfileRow')
class Profiles extends Table {
  @override
  String get tableName => 'profile';
  IntColumn get id => integer().check(id.equals(1))();
  IntColumn get dayCutoffHour => integer()
      .withDefault(const Constant(4))
      .check(dayCutoffHour.isBetweenValues(0, 6))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('LearningGoalRow')
class LearningGoals extends Table {
  @override
  String get tableName => 'learning_goal';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get scopeText => text().nullable()();
  TextColumn get dueDate => text().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant('active'))
      .check(status.isIn(['active', 'paused', 'done']))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
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
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get kind => text()
      .withDefault(const Constant('text'))
      .check(kind.isIn(['text', 'slides', 'book', 'other']))();
  TextColumn get sourceRef => text().nullable()();
  TextColumn get sourceFileName => text().nullable()();
  TextColumn get sourceFileHash =>
      text().nullable().references(AssetObjects, #hash)();
  IntColumn get goalId => integer().nullable().references(
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
}

@TableIndex(name: 'idx_material_page_material', columns: {#materialId, #pageNo})
@DataClassName('MaterialPageRow')
class MaterialPages extends Table {
  @override
  String get tableName => 'material_page';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get materialId =>
      integer().references(Materials, #id, onDelete: KeyAction.cascade)();
  IntColumn get pageNo => integer().check(pageNo.isBiggerThanValue(0))();
  TextColumn get label => text().nullable()();
  TextColumn get content => text()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {materialId, pageNo},
  ];
}

@TableIndex(name: 'idx_conversation_status', columns: {#status, #updatedAt})
@TableIndex(name: 'idx_conversation_goal', columns: {#goalId})
@TableIndex(name: 'idx_conversation_material', columns: {#materialId})
@DataClassName('ConversationRow')
class Conversations extends Table {
  @override
  String get tableName => 'conversation';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().nullable()();
  IntColumn get goalId => integer().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get materialId => integer().nullable().references(
    Materials,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get pageNo => integer().nullable()();
  TextColumn get sourceRef => text().nullable()();
  TextColumn get contextText => text().nullable()();
  IntColumn get questionMessageId => integer().nullable()();
  TextColumn get entryKind => text()
      .withDefault(const Constant('text'))
      .check(entryKind.isIn(['text', 'photo', 'text_photo']))();
  TextColumn get status => text()
      .withDefault(const Constant('open'))
      .check(status.isIn(['open', 'ended']))();
  TextColumn get endedAt => text().nullable()();
  TextColumn get lastMessageAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@TableIndex(
  name: 'idx_message_conversation',
  columns: {#conversationId, #createdAt},
)
@DataClassName('MessageRow')
class Messages extends Table {
  @override
  String get tableName => 'message';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get conversationId =>
      integer().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get role =>
      text().check(role.isIn(['user', 'assistant', 'system']))();
  TextColumn get content => text()();
  TextColumn get imagePathsJson => text().nullable()();
  TextColumn get structuredJson => text().nullable()();
  TextColumn get createdAt => text()();
}

@TableIndex(name: 'idx_study_plan_material', columns: {#materialId, #status})
@DataClassName('StudyPlanRow')
class StudyPlans extends Table {
  @override
  String get tableName => 'study_plan';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get materialId => integer().nullable().references(
    Materials,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get goalId => integer().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get conversationId => integer().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get title => text()();
  IntColumn get pageFrom => integer().nullable()();
  IntColumn get pageTo => integer().nullable()();
  IntColumn get currentPage => integer().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant('active'))
      .check(status.isIn(['active', 'paused', 'done']))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
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
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get conversationId => integer().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get studyPlanId => integer().nullable().references(
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
      .check(status.isIn(['todo', 'doing', 'done', 'deferred']))();
  TextColumn get source => text()
      .withDefault(const Constant('user'))
      .check(source.isIn(['user', 'ai']))();
  TextColumn get originJson => text().nullable()();
  TextColumn get completedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('TimetableEntryRow')
class TimetableEntries extends Table {
  @override
  String get tableName => 'timetable_entry';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get weekday => integer().check(weekday.isBetweenValues(1, 7))();
  TextColumn get startTime => text()();
  TextColumn get endTime => text()();
  TextColumn get title => text()();
  TextColumn get location => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<String> get customConstraints => const ['CHECK (end_time > start_time)'];
}

@TableIndex(name: 'idx_schedule_start', columns: {#startAt})
@TableIndex(name: 'idx_schedule_plan', columns: {#planItemId})
@DataClassName('ScheduleBlockRow')
class ScheduleBlocks extends Table {
  @override
  String get tableName => 'schedule_block';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get planItemId =>
      integer().references(PlanItems, #id, onDelete: KeyAction.cascade)();
  TextColumn get startAt => text()();
  TextColumn get endAt => text()();
  TextColumn get source => text()
      .withDefault(const Constant('user'))
      .check(source.isIn(['user', 'ai']))();
  TextColumn get status => text()
      .withDefault(const Constant('planned'))
      .check(status.isIn(['planned', 'done', 'cancelled']))();
  IntColumn get locked =>
      integer().withDefault(const Constant(0)).check(locked.isIn([0, 1]))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  List<String> get customConstraints => const ['CHECK (end_at > start_at)'];
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
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().nullable().references(
    LearningGoals,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get planItemId => integer().nullable().references(
    PlanItems,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get conversationId => integer().nullable().references(
    Conversations,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get summary => text().nullable()();
  TextColumn get outcome =>
      text().nullable().check(outcome.isIn(['done', 'partial', 'not_done']))();
  TextColumn get startedAt => text()();
  TextColumn get endedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
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
  IntColumn get id => integer().autoIncrement()();
  IntColumn get conversationId =>
      integer().references(Conversations, #id, onDelete: KeyAction.cascade)();
  IntColumn get sessionId => integer().nullable().references(
    StudySessions,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get redoOfAttemptId => integer().nullable().references(
    Attempts,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get userAnswer => text().nullable()();
  TextColumn get solution => text().nullable()();
  IntColumn get isCorrect =>
      integer().nullable().check(isCorrect.isIn([0, 1]))();
  IntColumn get independent =>
      integer().nullable().check(independent.isIn([0, 1]))();
  IntColumn get delayed =>
      integer().withDefault(const Constant(0)).check(delayed.isIn([0, 1]))();
  TextColumn get helpJson => text().nullable()();
  TextColumn get feedback => text().nullable()();
  TextColumn get submittedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@TableIndex(name: 'idx_assessment_attempt', columns: {#attemptId, #kind})
@DataClassName('AssessmentRow')
class Assessments extends Table {
  @override
  String get tableName => 'assessment';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get attemptId =>
      integer().references(Attempts, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind => text().check(kind.isIn(['model', 'user']))();
  TextColumn get result => text()();
  TextColumn get basis => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@TableIndex(name: 'idx_memory_status', columns: {#status, #kind})
@TableIndex(name: 'idx_memory_valid', columns: {#validUntil})
@DataClassName('MemoryRow')
class Memories extends Table {
  @override
  String get tableName => 'memory';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => text().check(
    kind.isIn(['preference', 'constraint', 'difficulty', 'progress']),
  )();
  TextColumn get content => text()();
  TextColumn get scope => text().nullable()();
  TextColumn get sourceKind => text().check(
    sourceKind.isIn(['user', 'message', 'attempt', 'session']),
  )();
  IntColumn get sourceId => integer().nullable()();
  TextColumn get validUntil => text().nullable()();
  TextColumn get status => text()
      .withDefault(const Constant('active'))
      .check(status.isIn(['active', 'superseded', 'deleted']))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_revision_request '
  'ON revision_commit(request_id) WHERE request_id IS NOT NULL',
)
@TableIndex(name: 'idx_revision_commit_parent', columns: {#parentId})
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
  TextColumn get actor => text().check(actor.isIn(['user', 'ai', 'system']))();
  TextColumn get action => text()();
  TextColumn get requestId => text().nullable()();
  IntColumn get restoredCommitId => integer().nullable()();
  IntColumn get revertedCommitId => integer().nullable()();
  IntColumn get changeCount => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
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
  TextColumn get op => text().check(op.isIn(['insert', 'update', 'delete']))();
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {commitId, seq};
}

@DataClassName('RevisionRefRow')
class RevisionRefs extends Table {
  @override
  String get tableName => 'revision_ref';
  TextColumn get name => text()();
  IntColumn get commitId => integer()();
  TextColumn get note => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {name};
}

@TableIndex(name: 'idx_revision_checkpoint_commit', columns: {#commitId, #id})
@DataClassName('RevisionCheckpointRow')
class RevisionCheckpoints extends Table {
  @override
  String get tableName => 'revision_checkpoint';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind =>
      text().check(kind.isIn(['initial', 'periodic', 'trimmed', 'named']))();
  IntColumn get commitId => integer()();
  TextColumn get projectionJson => text()();
  TextColumn get assetHashesJson => text()();
  TextColumn get checksum => text()();
  TextColumn get createdAt => text()();
}

@DataClassName('RevisionContextRow')
class RevisionContexts extends Table {
  @override
  String get tableName => 'revision_context';
  IntColumn get id => integer().check(id.equals(1))();
  IntColumn get activeCommit => integer().nullable()();
  IntColumn get suppress =>
      integer().withDefault(const Constant(0)).check(suppress.isIn([0, 1]))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('RevisionSequenceRow')
class RevisionSequences extends Table {
  @override
  String get tableName => 'revision_sequence';
  IntColumn get id => integer().check(id.equals(1))();
  IntColumn get nextCommit => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
