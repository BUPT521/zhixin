/// 当前库的结构信息，由 drift 生成代码里的表类派生。
///
/// 建表语句与索引写在 [AppDatabase] 的表类上，由 drift 负责执行；恢复预检、
/// 版本引擎与文档比对只读这里，不再手写第二份表清单或 DDL 文本。drift 的
/// `allTables` 与 `allSchemaEntities` 是实例成员，[schemaProbe] 提供一个不打开
/// 连接的实例来读取它们，避免为了拿结构信息多开一个数据库。
library;

import 'package:drift/drift.dart' show Index, LazyDatabase;

import 'drift/app_database.dart';

/// 只读取生成代码里表、列与索引定义的实例；任何查询都会抛出。
final AppDatabase schemaProbe = AppDatabase(
  LazyDatabase(() => throw StateError('结构元数据不需要打开数据库')),
);

/// 库里应当存在的表，恢复校验按这份清单核对。
Set<String> schemaTableNames() => const {
  'app_meta',
  'profile',
  'learning_goal',
  'material',
  'material_page',
  'conversation',
  'message',
  'plan_item',
  'timetable_entry',
  'schedule_block',
  'study_session',
  'study_plan',
  'attempt',
  'assessment',
  'memory',
  'revision_commit',
  'revision_change',
  'revision_ref',
  'revision_checkpoint',
  'revision_context',
  'revision_sequence',
  'asset_object',
  'asset_chunk',
};

/// 每张表必须有的字段；恢复时缺一列就拒绝，不让半套结构进正式库。
const Map<String, List<String>> requiredColumns = {
  'app_meta': ['key', 'value', 'updated_at'],
  'profile': ['id', 'day_cutoff_hour', 'created_at', 'updated_at'],
  'learning_goal': ['id', 'title', 'scope_text', 'due_date', 'status'],
  'material': [
    'id',
    'title',
    'kind',
    'source_ref',
    'source_file_name',
    'source_file_hash',
    'goal_id',
  ],
  'material_page': ['id', 'material_id', 'page_no', 'label', 'content'],
  'plan_item': [
    'id',
    'goal_id',
    'conversation_id',
    'study_plan_id',
    'seq',
    'title',
    'note',
    'page_from',
    'page_to',
    'due_at',
    'est_minutes',
    'priority',
    'status',
    'source',
  ],
  'timetable_entry': [
    'id',
    'weekday',
    'start_time',
    'end_time',
    'title',
    'location',
  ],
  'schedule_block': [
    'id',
    'plan_item_id',
    'start_at',
    'end_at',
    'source',
    'status',
    'locked',
  ],
  'study_session': [
    'id',
    'goal_id',
    'plan_item_id',
    'conversation_id',
    'summary',
    'outcome',
    'started_at',
    'ended_at',
  ],
  'study_plan': [
    'id',
    'material_id',
    'goal_id',
    'conversation_id',
    'title',
    'page_from',
    'page_to',
    'current_page',
    'status',
  ],
  'attempt': [
    'id',
    'conversation_id',
    'session_id',
    'redo_of_attempt_id',
    'user_answer',
    'solution',
    'is_correct',
    'independent',
    'delayed',
    'help_json',
    'feedback',
    'submitted_at',
  ],
  'assessment': ['id', 'attempt_id', 'kind', 'result', 'basis', 'created_at'],
  'conversation': [
    'id',
    'title',
    'goal_id',
    'material_id',
    'page_no',
    'source_ref',
    'context_text',
    'question_message_id',
    'entry_kind',
    'status',
    'ended_at',
    'last_message_at',
    'created_at',
    'updated_at',
  ],
  'message': [
    'id',
    'conversation_id',
    'role',
    'content',
    'image_paths_json',
    'structured_json',
    'created_at',
  ],
  'memory': [
    'id',
    'kind',
    'content',
    'scope',
    'source_kind',
    'source_id',
    'valid_until',
    'status',
  ],
  'revision_commit': [
    'id',
    'parent_id',
    'generation',
    'actor',
    'action',
    'request_id',
    'restored_commit_id',
    'reverted_commit_id',
    'change_count',
    'created_at',
  ],
  'revision_change': [
    'commit_id',
    'seq',
    'table_name',
    'row_key',
    'op',
    'before_json',
    'after_json',
  ],
  'revision_ref': ['name', 'commit_id', 'note', 'created_at', 'updated_at'],
  'revision_checkpoint': [
    'id',
    'kind',
    'commit_id',
    'projection_json',
    'asset_hashes_json',
    'checksum',
    'created_at',
  ],
  'revision_context': ['id', 'active_commit', 'suppress'],
  'revision_sequence': ['id', 'next_commit'],
  'asset_object': ['hash', 'byte_length', 'created_at'],
  'asset_chunk': ['hash', 'seq', 'data'],
};

/// 表类上声明的索引名；建表时由 drift 创建，恢复预检按它核对包里的索引。
Set<String> schemaIndexNames() => {
  for (final entity in schemaProbe.allSchemaEntities.whereType<Index>())
    entity.entityName,
};
