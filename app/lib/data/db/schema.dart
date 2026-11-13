/// 本地库的完整 DDL（01 第 4–5 章，开发期 schema 26）。
///
/// 15 张业务表：基础、学习、交互、时间、材料与评估五组；另有数据版本与附件
/// 对象 8 张表，以及打开时按业务表结构生成的采集暂存表与触发器（见
/// `data/revisions`）。档案只保留每日截止小时，消息不再保存回答版本，学习
/// 判断不再保存来源快照，记忆不再保存生效时刻。讨论可以没有目标归属，
/// 也可以带材料页码；一条讨论就是一条学习记录，题目由开始作答时确定的用户
/// 消息与图片派生，作答直接挂在这条记录上。学习事项只保存一段说明，不再分
/// 动作与结束条件；作答是否做对可以留空，表示暂不判断；自评由作答记录推出，
/// 不再单独保存。系统学习的步骤就是学习事项，计划只保存材料范围、顺序与继续
/// 位置。时间块只保存固定或弹性属性，改期按用户每次确认的方案执行。状态只保留有
/// 对应操作的值：目标为进行中、暂停、结束，事项为待办、进行中、完成、暂缓，
/// 时间块为待开始、完成、取消。旧库在打开时清空并按本结构重建，不保留迁移。
library;

/// 建库语句；顺序按外键依赖排，先建被引用的表。
List<String> schemaStatements() => const [
  _appMeta,
  _profile,
  _learningGoal,
  _assetObject,
  _material,
  _materialPage,
  _conversation,
  _message,
  _studyPlan,
  _planItem,
  _timetableEntry,
  _scheduleBlock,
  _studySession,
  _attempt,
  _assessment,
  _memory,
  _revisionCommit,
  _revisionChange,
  _revisionRef,
  _revisionCheckpoint,
  _revisionContext,
  _revisionSequence,
  _assetChunk,
  ..._indexes,
];

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

const String _appMeta = '''
CREATE TABLE IF NOT EXISTS app_meta (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  updated_at  TEXT NOT NULL
)''';

const String _profile = '''
CREATE TABLE IF NOT EXISTS profile (
  id                   INTEGER PRIMARY KEY CHECK (id = 1),
  day_cutoff_hour      INTEGER NOT NULL DEFAULT 4 CHECK (day_cutoff_hour BETWEEN 0 AND 6),
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL
)''';

const String _learningGoal = '''
CREATE TABLE IF NOT EXISTS learning_goal (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  title       TEXT NOT NULL,
  scope_text  TEXT,
  due_date    TEXT,
  status      TEXT NOT NULL DEFAULT 'active'
              CHECK (status IN ('active', 'paused', 'done')),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
)''';

const String _material = '''
CREATE TABLE IF NOT EXISTS material (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  title       TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'text'
              CHECK (kind IN ('text', 'slides', 'book', 'other')),
  source_ref  TEXT,
  source_file_name TEXT,
  source_file_hash TEXT REFERENCES asset_object(hash),
  goal_id     INTEGER REFERENCES learning_goal(id) ON DELETE SET NULL,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  CHECK ((source_file_name IS NULL) = (source_file_hash IS NULL))
)''';

const String _materialPage = '''
CREATE TABLE IF NOT EXISTS material_page (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  material_id INTEGER NOT NULL REFERENCES material(id) ON DELETE CASCADE,
  page_no     INTEGER NOT NULL CHECK (page_no > 0),
  label       TEXT,
  content     TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  UNIQUE (material_id, page_no)
)''';

const String _conversation = '''
CREATE TABLE IF NOT EXISTS conversation (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  title            TEXT,
  goal_id          INTEGER REFERENCES learning_goal(id) ON DELETE SET NULL,
  material_id      INTEGER REFERENCES material(id) ON DELETE SET NULL,
  page_no          INTEGER,
  source_ref       TEXT,
  context_text     TEXT,
  question_message_id INTEGER,
  entry_kind       TEXT NOT NULL DEFAULT 'text'
                   CHECK (entry_kind IN ('text', 'photo', 'text_photo')),
  status           TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'ended')),
  ended_at         TEXT,
  last_message_at  TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
)''';

const String _message = '''
CREATE TABLE IF NOT EXISTS message (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id  INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  role             TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content          TEXT NOT NULL,
  image_paths_json TEXT,
  structured_json  TEXT,
  created_at       TEXT NOT NULL
)''';

const String _planItem = '''
CREATE TABLE IF NOT EXISTS plan_item (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id         INTEGER REFERENCES learning_goal(id) ON DELETE SET NULL,
  conversation_id INTEGER REFERENCES conversation(id) ON DELETE SET NULL,
  study_plan_id   INTEGER REFERENCES study_plan(id) ON DELETE CASCADE,
  seq             INTEGER CHECK (seq IS NULL OR seq > 0),
  title           TEXT NOT NULL,
  note            TEXT,
  page_from       INTEGER CHECK (page_from IS NULL OR page_from > 0),
  page_to         INTEGER CHECK (page_to IS NULL OR page_to > 0),
  due_at          TEXT,
  est_minutes     INTEGER CHECK (est_minutes IS NULL OR est_minutes BETWEEN 5 AND 240),
  priority        INTEGER NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 2),
  status          TEXT NOT NULL DEFAULT 'todo'
                  CHECK (status IN ('todo', 'doing', 'done', 'deferred')),
  source          TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'ai')),
  origin_json     TEXT,
  completed_at    TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
)''';

const String _timetableEntry = '''
CREATE TABLE IF NOT EXISTS timetable_entry (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  weekday     INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  start_time  TEXT NOT NULL,
  end_time    TEXT NOT NULL,
  title       TEXT NOT NULL,
  location    TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  CHECK (end_time > start_time)
)''';

const String _scheduleBlock = '''
CREATE TABLE IF NOT EXISTS schedule_block (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  plan_item_id  INTEGER NOT NULL REFERENCES plan_item(id) ON DELETE CASCADE,
  start_at      TEXT NOT NULL,
  end_at        TEXT NOT NULL,
  source        TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'ai')),
  status        TEXT NOT NULL DEFAULT 'planned'
                CHECK (status IN ('planned', 'done', 'cancelled')),
  locked        INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  CHECK (end_at > start_at)
)''';

const String _studySession = '''
CREATE TABLE IF NOT EXISTS study_session (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id         INTEGER REFERENCES learning_goal(id) ON DELETE SET NULL,
  plan_item_id    INTEGER REFERENCES plan_item(id) ON DELETE SET NULL,
  conversation_id INTEGER REFERENCES conversation(id) ON DELETE CASCADE,
  summary         TEXT,
  outcome       TEXT CHECK (outcome IN ('done', 'partial', 'not_done')),
  started_at    TEXT NOT NULL,
  ended_at      TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
)''';

const String _studyPlan = '''
CREATE TABLE IF NOT EXISTS study_plan (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  material_id     INTEGER REFERENCES material(id) ON DELETE SET NULL,
  goal_id         INTEGER REFERENCES learning_goal(id) ON DELETE SET NULL,
  conversation_id INTEGER REFERENCES conversation(id) ON DELETE SET NULL,
  title           TEXT NOT NULL,
  page_from       INTEGER,
  page_to         INTEGER,
  current_page    INTEGER,
  status          TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'paused', 'done')),
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
)''';

const String _attempt = '''
CREATE TABLE IF NOT EXISTS attempt (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  session_id     INTEGER REFERENCES study_session(id) ON DELETE SET NULL,
  redo_of_attempt_id INTEGER REFERENCES attempt(id) ON DELETE SET NULL,
  user_answer    TEXT,
  solution       TEXT,
  is_correct     INTEGER CHECK (is_correct IN (0, 1)),
  independent    INTEGER CHECK (independent IN (0, 1)),
  delayed        INTEGER NOT NULL DEFAULT 0 CHECK (delayed IN (0, 1)),
  help_json      TEXT,
  feedback       TEXT,
  submitted_at   TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
)''';

const String _assessment = '''
CREATE TABLE IF NOT EXISTS assessment (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  attempt_id   INTEGER NOT NULL REFERENCES attempt(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('model', 'user')),
  result       TEXT NOT NULL,
  basis        TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
)''';

const String _memory = '''
CREATE TABLE IF NOT EXISTS memory (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  kind         TEXT NOT NULL
               CHECK (kind IN ('preference', 'constraint', 'difficulty', 'progress')),
  content      TEXT NOT NULL,
  scope        TEXT,
  source_kind  TEXT NOT NULL CHECK (source_kind IN ('user', 'message', 'attempt', 'session')),
  source_id    INTEGER,
  valid_until  TEXT,
  status       TEXT NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'superseded', 'deleted')),
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
)''';

/// 一次业务写入的提交；`parent_id` 指向提交序列的前一项，初始基线为 0。
const String _revisionCommit = '''
CREATE TABLE IF NOT EXISTS revision_commit (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id           INTEGER REFERENCES revision_commit(id) ON DELETE SET NULL,
  generation          INTEGER NOT NULL,
  actor               TEXT NOT NULL CHECK (actor IN ('user', 'ai', 'system')),
  action              TEXT NOT NULL,
  request_id          TEXT,
  restored_commit_id  INTEGER,
  reverted_commit_id  INTEGER,
  change_count        INTEGER NOT NULL DEFAULT 0,
  created_at          TEXT NOT NULL
)''';

/// 提交内的净变化；更新只保存发生变化的列。
const String _revisionChange = '''
CREATE TABLE IF NOT EXISTS revision_change (
  commit_id    INTEGER NOT NULL REFERENCES revision_commit(id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,
  table_name   TEXT NOT NULL,
  row_key      TEXT NOT NULL,
  op           TEXT NOT NULL CHECK (op IN ('insert', 'update', 'delete')),
  before_json  TEXT,
  after_json   TEXT,
  PRIMARY KEY (commit_id, seq)
)''';

/// `HEAD` 与命名版本的指向；命名版本可以附加一句备注。
const String _revisionRef = '''
CREATE TABLE IF NOT EXISTS revision_ref (
  name        TEXT PRIMARY KEY,
  commit_id   INTEGER NOT NULL,
  note        TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
)''';

/// 初始基线、周期检查点、裁剪后保留的基线与命名版本固化点。
const String _revisionCheckpoint = '''
CREATE TABLE IF NOT EXISTS revision_checkpoint (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  kind              TEXT NOT NULL
                    CHECK (kind IN ('initial', 'periodic', 'trimmed', 'named')),
  commit_id         INTEGER NOT NULL,
  projection_json   TEXT NOT NULL,
  asset_hashes_json TEXT NOT NULL,
  checksum          TEXT NOT NULL,
  created_at        TEXT NOT NULL
)''';

/// 当前命令事务的提交编号；触发器据此判断是否采集。
const String _revisionContext = '''
CREATE TABLE IF NOT EXISTS revision_context (
  id            INTEGER PRIMARY KEY CHECK (id = 1),
  active_commit INTEGER,
  suppress      INTEGER NOT NULL DEFAULT 0 CHECK (suppress IN (0, 1))
)''';

/// 提交编号分配；即使没有净变化也不回收编号，避免与暂存记录混淆。
const String _revisionSequence = '''
CREATE TABLE IF NOT EXISTS revision_sequence (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  next_commit INTEGER NOT NULL
)''';

/// 附件对象按内容哈希去重，业务表和版本明细只保存哈希引用。
const String _assetObject = '''
CREATE TABLE IF NOT EXISTS asset_object (
  hash         TEXT PRIMARY KEY,
  byte_length  INTEGER NOT NULL CHECK (byte_length >= 0),
  created_at   TEXT NOT NULL
)''';

/// 附件按固定大小分块存放，读取和导出时按 `seq` 拼接。
const String _assetChunk = '''
CREATE TABLE IF NOT EXISTS asset_chunk (
  hash  TEXT NOT NULL REFERENCES asset_object(hash) ON DELETE CASCADE,
  seq   INTEGER NOT NULL CHECK (seq >= 0),
  data  BLOB NOT NULL,
  PRIMARY KEY (hash, seq)
)''';

const List<String> _indexes = [
  'CREATE INDEX IF NOT EXISTS idx_material_goal ON material(goal_id)',
  'CREATE INDEX IF NOT EXISTS idx_material_page_material '
      'ON material_page(material_id, page_no)',
  'CREATE INDEX IF NOT EXISTS idx_plan_item_status_due '
      'ON plan_item(status, due_at)',
  'CREATE INDEX IF NOT EXISTS idx_plan_item_goal ON plan_item(goal_id)',
  'CREATE INDEX IF NOT EXISTS idx_plan_item_conversation '
      'ON plan_item(conversation_id)',
  'CREATE INDEX IF NOT EXISTS idx_schedule_start ON schedule_block(start_at)',
  'CREATE INDEX IF NOT EXISTS idx_schedule_plan '
      'ON schedule_block(plan_item_id)',
  'CREATE INDEX IF NOT EXISTS idx_session_plan '
      'ON study_session(plan_item_id, started_at)',
  'CREATE INDEX IF NOT EXISTS idx_session_conversation '
      'ON study_session(conversation_id, ended_at)',
  'CREATE INDEX IF NOT EXISTS idx_study_plan_material '
      'ON study_plan(material_id, status)',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_plan_item_study_seq '
      'ON plan_item(study_plan_id, seq)',
  'CREATE INDEX IF NOT EXISTS idx_attempt_conversation '
      'ON attempt(conversation_id, submitted_at)',
  'CREATE INDEX IF NOT EXISTS idx_attempt_session ON attempt(session_id)',
  'CREATE INDEX IF NOT EXISTS idx_attempt_redo ON attempt(redo_of_attempt_id)',
  'CREATE INDEX IF NOT EXISTS idx_assessment_attempt '
      'ON assessment(attempt_id, kind)',
  'CREATE INDEX IF NOT EXISTS idx_conversation_status '
      'ON conversation(status, updated_at)',
  'CREATE INDEX IF NOT EXISTS idx_conversation_goal '
      'ON conversation(goal_id)',
  'CREATE INDEX IF NOT EXISTS idx_conversation_material '
      'ON conversation(material_id)',
  'CREATE INDEX IF NOT EXISTS idx_message_conversation '
      'ON message(conversation_id, created_at)',
  'CREATE INDEX IF NOT EXISTS idx_memory_status ON memory(status, kind)',
  'CREATE INDEX IF NOT EXISTS idx_memory_valid ON memory(valid_until)',
  'CREATE INDEX IF NOT EXISTS idx_revision_change_target '
      'ON revision_change(table_name, row_key)',
  'CREATE INDEX IF NOT EXISTS idx_revision_change_commit '
      'ON revision_change(commit_id, seq)',
  'CREATE INDEX IF NOT EXISTS idx_revision_checkpoint_commit '
      'ON revision_checkpoint(commit_id, id)',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_revision_request '
      'ON revision_commit(request_id) WHERE request_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_revision_commit_parent '
      'ON revision_commit(parent_id)',
  'CREATE INDEX IF NOT EXISTS idx_asset_chunk_hash ON asset_chunk(hash, seq)',
];
