import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:zhixin/data/db/fts.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/rules/binary_bigrams.dart';

import '../support/test_db.dart';

/// ADR-0013 的关键约定：索引与查询用同一套二元组，索引跟着业务行同步更新。
void main() {
  test('SQL 切词与 Dart 切词切出同一批词', () {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    final statement = db.prepare('SELECT ${bigramsExpression()}');
    addTearDown(statement.close);
    const texts = [
      '矩阵的秩是怎么定义的',
      '热力学第二定律：孤立系统的熵不会减少，熵是状态函数。',
      '例 3-2 求条件概率 P(A|B)',
      '  前后有空白  中间也有  ',
      'HELLO World 混合大小写',
      '第3章 第 8 题',
      '秩 熵 ΑΒ café ångström فارسی',
      '只有一个字 a_b',
      '',
    ];
    for (final text in texts) {
      final indexed = (statement.select([text]).first.values.first as String?)
          ?.trim();
      // 词序不参与比对：索引只要切出同一批词就能被同一套查询命中。
      expect(
        (indexed ?? '')
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .toSet(),
        bigrams(text).toSet(),
        reason: '文本「$text」两边切出的词不一致',
      );
    }
  });

  test('写入、修改与删除业务行时索引跟着更新', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    const stamp = '2026-11-14 10:00:00';
    await db.insert('conversation', {
      'id': 1,
      'title': '讨论',
      'entry_kind': 'text',
      'status': 'open',
      'created_at': stamp,
      'updated_at': stamp,
    });
    await db.insert('message', {
      'id': 1,
      'conversation_id': 1,
      'role': 'user',
      'content': '矩阵的秩是线性无关行向量的最大个数',
      'created_at': stamp,
    });

    Future<Set<int>> hits(String query) async {
      final rows = await db.rawQuery(
        'SELECT rowid FROM message_fts WHERE message_fts MATCH ?',
        [ftsQuery(bigrams(query))],
      );
      return {for (final row in rows) row['rowid']! as int};
    }

    expect(await hits('矩阵的秩'), {1});
    expect(await hits('概率论'), isEmpty);

    await db.update(
      'message',
      {'content': '条件概率与独立性'},
      where: 'id = ?',
      whereArgs: [1],
    );
    expect(await hits('矩阵'), isEmpty, reason: '改过之后旧词不应再命中');
    expect(await hits('条件概率'), {1});

    await db.delete('message', where: 'id = ?', whereArgs: [1]);
    expect(await hits('条件概率'), isEmpty, reason: '删除之后索引行也删掉');
  });

  test('材料标签及作答题解和反馈参与关键词检索', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    const stamp = '2026-11-14 10:00:00';
    await db.insert('material', {
      'id': 1,
      'title': '讲义',
      'created_at': stamp,
      'updated_at': stamp,
    });
    await db.insert('material_page', {
      'material_id': 1,
      'page_no': 1,
      'label': '傅里叶变换',
      'content': '基础内容',
      'created_at': stamp,
      'updated_at': stamp,
    });
    await db.insert('conversation', {
      'id': 1,
      'title': '讨论',
      'entry_kind': 'text',
      'status': 'open',
      'created_at': stamp,
      'updated_at': stamp,
    });
    await db.insert('attempt', {
      'id': 1,
      'conversation_id': 1,
      'user_answer': '试答',
      'solution': '柯西不等式',
      'feedback': '齐次化步骤',
      'submitted_at': stamp,
      'created_at': stamp,
      'updated_at': stamp,
    });

    final evidence = EvidenceRepository(db);
    const scope = EvidenceScope.userAll();
    expect(
      (await evidence.keyword('傅里叶变换', scope: scope)).single.identity,
      'material_page:1:1',
    );
    expect(
      (await evidence.keyword('柯西不等式', scope: scope)).single.identity,
      'attempt:1',
    );
    expect(
      (await evidence.keyword('齐次化步骤', scope: scope)).single.identity,
      'attempt:1',
    );
    await db.update(
      'attempt',
      {'feedback': '齐次化步骤已复核', 'solution': null},
      where: 'id = ?',
      whereArgs: [1],
    );
    expect(await evidence.keyword('柯西不等式', scope: scope), isEmpty);
    expect(
      (await evidence.keyword('齐次化步骤', scope: scope)).single.identity,
      'attempt:1',
    );
  });

  test('关键词按 BM25 取有限候选，同一命中的分页得分一致', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    const stamp = '2026-11-14 10:00:00';
    await db.insert('conversation', {
      'id': 1,
      'title': '讨论',
      'entry_kind': 'text',
      'status': 'open',
      'created_at': stamp,
      'updated_at': stamp,
    });
    for (final (id, content) in [(1, '矩阵 独立性 矩阵 独立性'), (2, '这里只讨论矩阵')]) {
      await db.insert('message', {
        'id': id,
        'conversation_id': 1,
        'role': 'user',
        'content': content,
        'created_at': stamp,
      });
    }
    final evidence = EvidenceRepository(db);
    const scope = EvidenceScope.userAll();
    const query = '矩阵 独立性';
    final hits = await evidence.keyword(query, scope: scope, limitPerKind: 1);
    expect(hits.single.location.messageId, 1);
    final paged = await evidence.allKeyword(query, scope: scope, batchSize: 1);
    expect(paged.map((hit) => hit.location.messageId), [2, 1]);
    expect(paged.last.score, hits.single.score);
    expect(paged.last.score, greaterThan(paged.first.score));
  });

  test('恢复整版数据之后索引与业务行一致', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    const stamp = '2026-11-14 10:00:00';
    // 先经命令写入一次，形成一条可恢复的提交。
    final transactions = WriteTransactions(rig.db);
    await transactions.run((txn) async {
      await txn.executor.insert('conversation', {
        'id': 1,
        'title': '讨论',
        'entry_kind': 'text',
        'status': 'open',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await txn.executor.insert('message', {
        'id': 1,
        'conversation_id': 1,
        'role': 'user',
        'content': '矩阵的秩',
        'created_at': stamp,
      });
    }, label: '写入消息');
    final head = await rig.engine.headId(rig.raw);
    expect(head, greaterThan(0));
    await rig.engine.restore(rig.raw, head, expectedHead: head);
    final rows = await rig.raw.rawQuery(
      'SELECT rowid FROM message_fts WHERE message_fts MATCH ?',
      [ftsQuery(bigrams('矩阵'))],
    );
    expect(rows.map((row) => row['rowid']), contains(1));
    // 索引表不进入版本投影：恢复只重放业务行，索引由版本引擎整份重建。
    final projection = await rig.engine.readProjection(rig.raw);
    for (final table in ftsTableNames()) {
      expect(projection, isNot(contains(table)));
    }
  });
}
