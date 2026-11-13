import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<int> addMemory(TestRig rig, String content) async {
    await rig.db.insert('memory', {
      'kind': 'preference',
      'content': content,
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    return rig.engine.headId(rig.raw);
  }

  Future<int> openConversation(TestRig rig) async {
    final conversationId = await rig.db.insert('conversation', {
      'title': '回执',
      'entry_kind': 'text',
      'status': 'open',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    return rig.db.insert('message', {
      'conversation_id': conversationId,
      'role': 'assistant',
      'content': '回答',
      'structured_json': '{}',
      'created_at': '2026-11-10T09:00:00',
    });
  }

  Future<Map<String, Object?>> readStructured(
    TestRig rig,
    int messageId,
  ) async {
    final rows = await rig.raw.query(
      'message',
      columns: ['structured_json'],
      where: 'id = ?',
      whereArgs: [messageId],
    );
    return jsonDecode(rows.single['structured_json']! as String)
        as Map<String, Object?>;
  }

  test('裁剪删掉旧提交后，消息里指向它的回执一并清理', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final messageId = await openConversation(rig);
    final oldCommit = await addMemory(rig, '旧记忆');
    for (var index = 0; index < 4; index++) {
      await addMemory(rig, '后续 $index');
    }
    final keptCommit = await addMemory(rig, '保留记忆');
    await rig.db.update(
      'message',
      {
        'structured_json': jsonEncode({
          'operations': [
            {'commit_id': oldCommit, 'text': '已添加安排：旧'},
            {'commit_id': keptCommit, 'text': '已添加安排：保留'},
          ],
          'memory_items': [
            {
              'id': 'old',
              'kind': 'preference',
              'content': '旧记忆',
              'source': 'user',
              'status': 'accepted',
              'commit_id': oldCommit,
            },
            {
              'id': 'kept',
              'kind': 'preference',
              'content': '保留记忆',
              'source': 'user',
              'status': 'accepted',
              'commit_id': keptCommit,
            },
          ],
        }),
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );

    final result = await rig.revisions.prune(keepCommits: 3);
    expect(result.removedCommits, greaterThan(0));

    final structured = await readStructured(rig, messageId);
    final operations = structured['operations']! as List;
    expect(operations, hasLength(1));
    expect((operations.single as Map)['commit_id'], keptCommit);
    final items = structured['memory_items']! as List;
    final oldItem = items.firstWhere((item) => (item as Map)['id'] == 'old');
    expect((oldItem as Map).containsKey('commit_id'), isFalse);
    final keptItem = items.firstWhere((item) => (item as Map)['id'] == 'kept');
    expect((keptItem as Map)['commit_id'], keptCommit);

    // 清理回执本身是一条普通提交，可以在历史里看到，但不能反向撤销。
    final head = await rig.engine.headId(rig.raw);
    final headCommit = await rig.engine.commitById(rig.raw, head);
    expect(headCommit!.action, clearDeadReceiptsAction);
    final reasons = await rig.revisions.undoBlockReasons([headCommit]);
    expect(reasons[head], contains('清理回执'));
    final undone = await rig.revisions.undoCommit(head);
    expect(undone.applied, isFalse);
  });

  test('清理历史后消息里的回执编号全部去掉，数据仍可重建', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final messageId = await openConversation(rig);
    final commitId = await addMemory(rig, '一条记忆');
    await rig.db.update(
      'message',
      {
        'structured_json': jsonEncode({
          'operations': [
            {'commit_id': commitId, 'text': '已添加安排：记忆'},
          ],
          'memory_items': [
            {
              'id': 'memory',
              'kind': 'preference',
              'content': '一条记忆',
              'source': 'user',
              'status': 'accepted',
              'commit_id': commitId,
            },
          ],
        }),
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );

    await rig.revisions.clearHistory();

    final structured = await readStructured(rig, messageId);
    expect(structured['operations'], isEmpty);
    final items = structured['memory_items']! as List;
    expect((items.single as Map).containsKey('commit_id'), isFalse);
    expect((items.single as Map)['status'], 'accepted');

    final head = await rig.engine.headId(rig.raw);
    final headCommit = await rig.engine.commitById(rig.raw, head);
    expect(headCommit!.action, clearDeadReceiptsAction);
    final projection = await rig.engine.projectionAt(rig.raw, head);
    final row = projection['message']![messageId.toString()]!;
    expect(
      row['structured_json']!.value,
      await _structuredText(rig, messageId),
    );
    expect(
      await rig.engine.commitById(rig.raw, headCommit.parentId!),
      isNotNull,
    );
  });

  test('没有失效回执时清理历史不额外形成提交', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await openConversation(rig);

    await rig.revisions.clearHistory();

    final commits = await rig.raw.query('revision_commit');
    expect(commits, hasLength(1));
    expect(commits.single['action'], '清理后保留');
    expect(commits.single['change_count'], 0);
  });
}

Future<String> _structuredText(TestRig rig, int messageId) async {
  final rows = await rig.raw.query(
    'message',
    columns: ['structured_json'],
    where: 'id = ?',
    whereArgs: [messageId],
  );
  return rows.single['structured_json']! as String;
}
