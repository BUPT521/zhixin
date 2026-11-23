import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart'
    show versionedTableNames;
import 'package:zhixin/data/revisions/revision_models.dart' show ChangeOp;
import 'package:zhixin/data/repository/assessment_repository.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/rules/uuid_v7.dart';

import '../../support/test_db.dart';

/// UUIDv7 主键（ADR-0018）：参与版本采集的 14 张业务表用文本主键，插入前由写入方生成，
/// 时间有序且带版本位与变体位；增量同步让两台设备按同一文本定位同一行，
/// 因此一次提交里的父行与子行引用必须能在这条提交的变更明细里对上。
///
/// 与 `drift_schema_test.dart` 的分工：那边核对建库结果、外键动作与复合主键，
/// 这里只核对主键的类型、生成形式与提交内引用，不重复它的断言。
DateTime _fixedClock() => DateTime(2026, 11, 16, 9);

/// UUIDv7 的规范文本：36 位小写、带连字符，第 7 字节高 4 位是版本 7，
/// 第 9 字节高 2 位是 RFC 9562 的变体 10xx。
final RegExp _uuidV7Text = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// 主键前 48 位是毫秒时间戳；跳过第 8 位之后的分隔符，拼回 12 位十六进制。
String _timePrefix(String id) => '${id.substring(0, 8)}${id.substring(9, 13)}';

int _timeStamp(String id) => int.parse(_timePrefix(id), radix: 16);

void _expectUuidV7(String id) {
  expect(_uuidV7Text.hasMatch(id), isTrue, reason: '不是 UUIDv7 文本：$id');
  expect(id, id.toLowerCase(), reason: '主键统一用小写十六进制');
  expect(id[14], '7', reason: '第 7 字节高 4 位是版本号');
  expect('89ab'.contains(id[19]), isTrue, reason: '变体位应当落在 RFC 9562 的 10xx');
}

/// 参与版本采集的业务表都用 UUIDv7 主键。
///
/// `profile` 已经删掉，每日截止小时并进 `app_meta` 的文本键；`memory_usage` 的
/// 编号改用 UUIDv5（审查 S17），`local_memory_use` 是本机缓冲表、行号自增，两张
/// 记忆使用表因此都不在业务表清单里，`memory_usage` 单独在下面核对。
Set<String> _uuidPrimaryKeyTables() => {...versionedTableNames};

void main() {
  test('主键是 36 位小写 UUIDv7，时间前缀取写入时刻', () {
    for (var i = 0; i < 200; i++) {
      _expectUuidV7(newUuidV7());
    }

    // 取一个比上一次生成更新的毫秒，时间前缀应当就是这一毫秒：
    // 生成器在同一毫秒内复用上一次的时间戳，因此这里先往前挪一秒。
    final at = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + 1000,
    );
    final id = newUuidV7(now: at);
    _expectUuidV7(id);
    expect(_timeStamp(id), at.millisecondsSinceEpoch);
  });

  test('同一毫秒内按写入顺序递增，序号用完借用下一毫秒也不回退', () {
    final at = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + 2000,
    );
    // 12 位序号每毫秒可生成 4096 个；超过之后借用下一毫秒，仍保持递增。
    final ids = [for (var i = 0; i < 5000; i++) newUuidV7(now: at)];

    expect(ids.toSet().length, ids.length, reason: '同一毫秒内生成的主键不重复');
    for (var i = 1; i < ids.length; i++) {
      expect(
        ids[i].compareTo(ids[i - 1]),
        greaterThan(0),
        reason: '第 $i 个主键没有排在前一个之后',
      );
    }
    // 前 4096 个落在同一毫秒，第 4097 个已经借到下一毫秒。
    expect(_timeStamp(ids.first), at.millisecondsSinceEpoch);
    expect(_timeStamp(ids[4095]), at.millisecondsSinceEpoch);
    expect(_timeStamp(ids[4096]), at.millisecondsSinceEpoch + 1);

    // 时间回拨沿用上一次的时间戳：新行仍排在前一行之后。
    final rolledBack = newUuidV7(
      now: DateTime.fromMillisecondsSinceEpoch(
        at.millisecondsSinceEpoch - 60000,
      ),
    );
    expect(_timeStamp(rolledBack), _timeStamp(ids.last));
    expect(rolledBack.compareTo(ids.last), greaterThan(0));
  });

  test('业务表的主键都是文本，外键列同为文本', () async {
    final db = await openTestDb();
    addTearDown(db.close);

    final uuidTables = _uuidPrimaryKeyTables();
    expect(uuidTables, hasLength(14), reason: '参与版本采集的 14 张业务表都用文本主键');

    final columnTypes = <String, Map<String, String>>{};
    for (final table in uuidTables) {
      final info = await db.rawQuery('PRAGMA table_info("$table")');
      columnTypes[table] = {
        for (final row in info)
          '${row['name']}': '${row['type']}'.toUpperCase(),
      };
      final primary = info.where((row) => (row['pk']! as int) > 0).toList();
      expect(primary, hasLength(1), reason: '$table 是单列主键');
      expect(
        '${primary.single['type']}'.toUpperCase(),
        'TEXT',
        reason: '$table 的主键应当是可写 UUIDv7 的文本',
      );
    }

    Future<String> primaryKeyType(String table) async {
      final info = await db.rawQuery('PRAGMA table_info("$table")');
      final primary = info.where((row) => (row['pk']! as int) > 0).toList();
      expect(primary, hasLength(1), reason: '$table 是单列主键');
      return '${primary.single['type']}'.toUpperCase();
    }

    for (final table in uuidTables) {
      final fks = await db.rawQuery('PRAGMA foreign_key_list("$table")');
      for (final fk in fks) {
        final column = '${fk['from']}';
        expect(
          columnTypes[table]![column],
          'TEXT',
          reason: '$table.$column 指向 ${fk['table']} 的文本主键',
        );
        // 引用目标同样按文本定位：除业务表之外还有按内容哈希保存
        // 附件的 asset_object，它的主键也是文本。
        expect(
          await primaryKeyType('${fk['table']}'),
          'TEXT',
          reason: '$table.$column 的引用目标 ${fk['table']} 用文本主键',
        );
      }
    }

    // 不参与版本采集的持久表只有设置表 app_meta：按名取值的文本键。
    final meta = await db.rawQuery('PRAGMA table_info("app_meta")');
    expect(
      '${meta.firstWhere((row) => (row['pk']! as int) > 0)['type']}'
          .toUpperCase(),
      'TEXT',
    );
    // 唯一的整数主键是版本引擎的单行状态：固定为 1，由安装时写入。
    final state = await db.rawQuery('PRAGMA table_info("revision_state")');
    expect(
      '${state.firstWhere((row) => (row['pk']! as int) > 0)['type']}'
          .toUpperCase(),
      'INTEGER',
    );
  });

  test('仓库插入时生成 UUIDv7 主键，外键写父行的同一份文本', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);

    final tasks = TaskRepository(rig.db, clock: _fixedClock);
    final schedule = ScheduleRepository(rig.db, clock: _fixedClock);
    final study = StudyRepository(rig.db, clock: _fixedClock);
    final conversations = ConversationRepository(rig.db, clock: _fixedClock);
    final attempts = AttemptRepository(rig.db, clock: _fixedClock);
    final assessments = AssessmentRepository(rig.db, clock: _fixedClock);
    final materials = MaterialRepository(rig.db, clock: _fixedClock);
    final studyPlans = StudyPlanRepository(rig.db, clock: _fixedClock);

    final goalId = await tasks.createGoal(title: '线代复习');
    final itemId = await tasks.createItem(
      title: '整理笔记',
      goalId: goalId,
      estMinutes: 30,
    );
    final timetableId = await schedule.addTimetable(
      weekday: 1,
      startTime: '08:00',
      endTime: '09:00',
      title: '线性代数',
    );
    final blockId = await schedule.addBlock(
      planItemId: itemId,
      start: DateTime(2026, 11, 17, 19),
      end: DateTime(2026, 11, 17, 19, 30),
    );
    final session = await study.start(goalId: goalId);
    final conversationId = await conversations.create(
      title: '条件概率',
      goalId: goalId,
    );
    final message = await conversations.append(
      conversationId,
      role: MessageRole.user,
      content: '为什么条件概率要除以条件事件发生的概率？',
    );
    final attempt = await attempts.ensureOpenAttempt(
      conversationId,
      sessionId: session.id,
    );
    final assessmentId = await assessments.add(
      attemptId: attempt.id,
      kind: AssessmentKind.user,
      result: '先看提示再独立做一遍',
    );
    final materialId = await materials.create(
      title: '概率论讲义',
      kind: MaterialKind.book,
    );
    final pageId = await materials.addPage(
      materialId: materialId,
      pageNo: 1,
      content: '条件概率是已知一个事件发生时另一个事件发生的概率。',
    );
    final planId = await studyPlans.create(
      title: '系统学习条件概率',
      materialId: materialId,
    );
    // 记忆按现有仓库写不进库（类别取值与库里的三分类对不上），直接写一行，
    // 标识同样由用例给出 UUIDv7 文本；记忆使用统计的行用仓库之外的方式写，
    // 统计行的编号按 ADR-0053 用 UUIDv5，这里只核对主键是文本、外键能对上。
    final memoryId = newUuidV7(now: _fixedClock());
    await insertRow(rig.db, 'memory', {
      'id': memoryId,
      'kind': 'semantic',
      'content': '先给提示，再看完整解答',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-17 19:00:00',
      'updated_at': '2026-11-17 19:00:00',
    });
    final usageId = newUuidV7(now: _fixedClock());
    await insertRow(rig.db, 'memory_usage', {
      'id': usageId,
      'memory_id': memoryId,
      'device_id': 'device-1',
      'updated_at': '2026-11-17 19:00:00',
    });
    // 本机缓冲表按行号自增，只留记忆编号、种类与时刻（审查 S16）。
    await insertRow(rig.db, 'local_memory_use', {
      'memory_id': memoryId,
      'kind': 'recall',
      'used_at': '2026-11-17 19:00:00',
    });

    // 每张业务表各插入一行，插入生成的标识就是 UUIDv7 文本。
    final ids = <String, String>{
      'learning_goal': goalId,
      'plan_item': itemId,
      'timetable_entry': timetableId,
      'schedule_block': blockId,
      'study_session': session.id,
      'conversation': conversationId,
      'message': message.id,
      'attempt': attempt.id,
      'assessment': assessmentId,
      'material': materialId,
      'material_page': pageId,
      'study_plan': planId,
      'memory': memoryId,
      'memory_usage': usageId,
    };
    expect(ids.keys.toSet(), _uuidPrimaryKeyTables());
    expect(ids.values.toSet(), hasLength(ids.length), reason: '同一时刻写入的行互不撞键');
    for (final entry in ids.entries) {
      _expectUuidV7(entry.value);
      final rows = await selectRows(
        rig.raw,
        entry.key,
        where: 'id = ?',
        whereArgs: [entry.value],
      );
      expect(rows, hasLength(1), reason: '${entry.key} 的主键按插入时的文本落库');
    }

    // 外键列写的是父行的同一份文本，读回时不需要另做类型转换。
    Future<String?> foreignKey(String table, String column) async =>
        (await selectRows(rig.raw, table)).single[column] as String?;
    expect(await foreignKey('plan_item', 'goal_id'), goalId);
    expect(await foreignKey('schedule_block', 'plan_item_id'), itemId);
    expect(await foreignKey('study_session', 'goal_id'), goalId);
    expect(await foreignKey('conversation', 'goal_id'), goalId);
    expect(await foreignKey('message', 'conversation_id'), conversationId);
    expect(await foreignKey('attempt', 'conversation_id'), conversationId);
    expect(await foreignKey('attempt', 'session_id'), session.id);
    expect(await foreignKey('assessment', 'attempt_id'), attempt.id);
    expect(await foreignKey('material_page', 'material_id'), materialId);
    expect(await foreignKey('study_plan', 'material_id'), materialId);
  });

  test('一次提交按 UUIDv7 文本记录变更，子行引用的父行在同一提交里', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);

    final tasks = TaskRepository(rig.db, clock: _fixedClock);
    final schedule = ScheduleRepository(rig.db, clock: _fixedClock);
    final study = StudyRepository(rig.db, clock: _fixedClock);
    final conversations = ConversationRepository(rig.db, clock: _fixedClock);
    final attempts = AttemptRepository(rig.db, clock: _fixedClock);
    final assessments = AssessmentRepository(rig.db, clock: _fixedClock);

    // 目标、事项、预约、场次、记录、消息、草稿与判断落在同一条提交里：
    // 同步到另一台设备时先应用父行的文本主键，子行的外键才对得上。
    final written = await WriteTransactions(rig.db, revisions: rig.engine).run((
      txn,
    ) async {
      final goalId = await tasks.createGoal(title: '线代复习', transaction: txn);
      final itemId = await tasks.createItem(
        title: '整理笔记',
        goalId: goalId,
        estMinutes: 30,
        transaction: txn,
      );
      final blockId = await schedule.addBlock(
        planItemId: itemId,
        start: DateTime(2026, 11, 17, 19),
        end: DateTime(2026, 11, 17, 19, 30),
        transaction: txn,
      );
      final session = await study.start(goalId: goalId, transaction: txn);
      final conversationId = await conversations.create(
        title: '条件概率',
        goalId: goalId,
        transaction: txn,
      );
      final message = await conversations.append(
        conversationId,
        role: MessageRole.user,
        content: '为什么条件概率要除以条件事件发生的概率？',
        transaction: txn,
      );
      final attempt = await attempts.ensureOpenAttempt(
        conversationId,
        sessionId: session.id,
        transaction: txn,
      );
      final assessmentId = await assessments.add(
        attemptId: attempt.id,
        kind: AssessmentKind.user,
        result: '先看提示再独立做一遍',
        transaction: txn,
      );
      return (
        goalId: goalId,
        itemId: itemId,
        blockId: blockId,
        sessionId: session.id,
        conversationId: conversationId,
        messageId: message.id,
        attemptId: attempt.id,
        assessmentId: assessmentId,
      );
    }, label: '一次写入');

    final head = await rig.engine.headId(rig.raw);
    final commit = await rig.engine.commitById(rig.raw, head);
    expect(commit!.action, '一次写入');
    final changes = await rig.engine.changesFor(rig.raw, head);
    expect(changes.map((change) => change.op).toSet(), {
      ChangeOp.insert,
    }, reason: '一次提交里的八行都是新增');

    final rowKeys = <String, Set<String>>{};
    for (final change in changes) {
      _expectUuidV7(change.rowKey);
      rowKeys.putIfAbsent(change.table, () => {}).add(change.rowKey);
    }

    // 变更明细里的 row_key 就是表里的主键文本，撤销与同步都按它定位。
    final expected = <String, String>{
      'learning_goal': written.goalId,
      'plan_item': written.itemId,
      'schedule_block': written.blockId,
      'study_session': written.sessionId,
      'conversation': written.conversationId,
      'message': written.messageId,
      'attempt': written.attemptId,
      'assessment': written.assessmentId,
    };
    expect(rowKeys.keys.toSet(), expected.keys.toSet());
    for (final entry in expected.entries) {
      expect(rowKeys[entry.key], {
        entry.value,
      }, reason: '${entry.key} 的变更明细应当按插入时的文本记录一次');
    }

    /// 子行在这次提交里写下的引用键。
    String reference(String table, String column) {
      final change = changes.firstWhere((change) => change.table == table);
      return '${change.after![column]!.value}';
    }

    // 每一条引用都指向同一提交里的父行：这台设备推送出去，另一台设备按
    // 变更明细就能先建父行、再建子行，不必回读一个不存在的键。
    final references = <(String, String, String)>[
      ('plan_item', 'goal_id', written.goalId),
      ('schedule_block', 'plan_item_id', written.itemId),
      ('study_session', 'goal_id', written.goalId),
      ('conversation', 'goal_id', written.goalId),
      ('message', 'conversation_id', written.conversationId),
      ('attempt', 'conversation_id', written.conversationId),
      ('attempt', 'session_id', written.sessionId),
      ('assessment', 'attempt_id', written.attemptId),
    ];
    final parents = {
      written.goalId: 'learning_goal',
      written.itemId: 'plan_item',
      written.sessionId: 'study_session',
      written.conversationId: 'conversation',
      written.attemptId: 'attempt',
    };
    for (final (table, column, parentId) in references) {
      expect(
        reference(table, column),
        parentId,
        reason: '$table.$column 写的是父行的文本主键',
      );
      final parentTable = parents[parentId]!;
      expect(
        rowKeys[parentTable],
        contains(parentId),
        reason: '$parentTable 的父行也在这次提交里',
      );
    }
  });
}
