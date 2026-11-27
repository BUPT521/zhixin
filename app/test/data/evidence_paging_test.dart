import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/material.dart';

import '../support/test_db.dart';

/// 四类来源各有命中、且时间精度只到秒的语料：字面查找要分页读完全部候选。
Future<void> _seed(RawDatabase db) async {
  final conversations = ConversationRepository(db);
  final attempts = AttemptRepository(db);
  final materials = MaterialRepository(db);

  final firstMaterial = await materials.create(
    title: '热力学讲义',
    kind: MaterialKind.book,
  );
  await materials.addPage(
    materialId: firstMaterial,
    pageNo: 1,
    content: '熵是状态函数，孤立系统的熵不会减少。',
  );
  await materials.addPage(
    materialId: firstMaterial,
    pageNo: 2,
    content: '时间箭头与熵增有关。',
  );
  final secondMaterial = await materials.create(title: '统计物理讲义');
  await materials.addPage(
    materialId: secondMaterial,
    pageNo: 1,
    content: '熵的统计解释与微观状态数有关。',
  );

  // 三条记录：第一条一次作答，第二条一问一答，第三条两次作答。
  final first = await conversations.create(title: '熵与时间');
  await conversations.append(first, role: MessageRole.user, content: '熵增与时间箭头');
  final firstAttempt = await attempts.ensureOpenAttempt(first);
  await attempts.submit(
    firstAttempt.id,
    answer: '熵是状态函数。',
    isCorrect: true,
    independent: true,
  );

  final second = await conversations.create(title: '熵的统计解释');
  await conversations.append(
    second,
    role: MessageRole.user,
    content: '熵和微观状态数',
  );
  await conversations.append(
    second,
    role: MessageRole.assistant,
    content: '熵越大，微观状态数越多。',
  );
  final secondAttempt = await attempts.ensureOpenAttempt(second);
  await attempts.submit(
    secondAttempt.id,
    answer: '因为熵增不可逆。',
    isCorrect: false,
    independent: false,
  );

  final third = await conversations.create(title: '再答一次熵');
  await conversations.append(third, role: MessageRole.user, content: '熵到底是什么');
  final thirdAttempt = await attempts.ensureOpenAttempt(third);
  await attempts.submit(
    thirdAttempt.id,
    answer: '熵是混乱程度的度量。',
    isCorrect: true,
    independent: true,
  );
  final thirdAgain = await attempts.ensureOpenAttempt(third);
  await attempts.submit(
    thirdAgain.id,
    answer: '熵也可以看成信息量。',
    isCorrect: true,
    independent: false,
  );
}

void main() {
  test('分页读完四类来源：不重复、不漏行，边界批次也能继续', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final repository = EvidenceRepository(db);
    const scope = EvidenceScope.userAll();

    // 一次读全的基准。
    final full = await repository.literal('熵', scope: scope, limitPerKind: 100);
    expect(full, isNotEmpty);

    for (final batchSize in [1, 2, 3, 100]) {
      final paged = <EvidenceHit>[];
      SearchCursor? cursor;
      var batches = 0;
      do {
        final page = await repository.searchBatch(
          '熵',
          scope: scope,
          batchSize: batchSize,
          after: cursor,
        );
        paged.addAll(page.hits);
        cursor = page.hasMore ? page.cursor : null;
        batches++;
        expect(batches, lessThan(50), reason: '游标没有前进时不能一直读下去');
      } while (cursor != null);

      final identities = paged.map((hit) => hit.identity).toList();
      expect(
        identities.toSet().length,
        identities.length,
        reason: '每批 $batchSize 条时同一条来源只能返回一次',
      );
      expect(
        identities.toSet(),
        full.map((hit) => hit.identity).toSet(),
        reason: '每批 $batchSize 条时全部命中都要翻到',
      );
    }
  });

  test('同一秒提交的作答按编号续读，翻页不重复', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final repository = EvidenceRepository(db);
    const scope = EvidenceScope.userAll();

    final full = await repository.literal('熵', scope: scope, limitPerKind: 100);
    final answers = full
        .where((hit) => hit.kind == EvidenceKind.answer)
        .toList();
    expect(answers, hasLength(4));
    // 语料里至少两条请求落在同一秒，翻页要按编号把同一时刻的作答分开。
    final stamps = answers
        .map((hit) => hit.createdAt!.millisecondsSinceEpoch ~/ 1000)
        .toList();
    expect(stamps.toSet().length, lessThan(stamps.length));

    final pagedAnswers = <String>[];
    SearchCursor? cursor;
    do {
      final page = await repository.searchBatch(
        '熵',
        scope: scope,
        batchSize: 1,
        after: cursor,
      );
      pagedAnswers.addAll(
        page.hits
            .where((hit) => hit.kind == EvidenceKind.answer)
            .map((hit) => hit.identity),
      );
      cursor = page.hasMore ? page.cursor : null;
    } while (cursor != null);

    expect(pagedAnswers.toSet(), answers.map((hit) => hit.identity).toSet());
    expect(pagedAnswers.length, answers.length);
  });

  test('某一类这一批没有记录时沿用上一批的位置，不再重复读到', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final repository = EvidenceRepository(db);
    const scope = EvidenceScope.userAll();

    // 第一批每类各读一条：四类都有记录，游标记下每类的位置。
    final first = await repository.searchBatch(
      '熵',
      scope: scope,
      batchSize: 1,
      after: null,
    );
    expect(first.hasMore, isTrue);
    final cursor = first.cursor!;
    expect(cursor.materialPage, isNotNull);
    expect(cursor.messageId, isNotNull);
    expect(cursor.questionId, isNotNull);
    expect(cursor.answer, isNotNull);

    // 第二批把批量放大到足以读完全部：每类的位置都在，因此不会重复返回第一批
    // 已经给过的记录，也不会漏掉后面的记录。
    final second = await repository.searchBatch(
      '熵',
      scope: scope,
      batchSize: 100,
      after: cursor,
    );
    final rest = second.hits.map((hit) => hit.identity).toSet();
    expect(
      rest.intersection(first.hits.map((hit) => hit.identity).toSet()),
      isEmpty,
    );
    expect(
      {...first.hits.map((hit) => hit.identity), ...rest},
      (await repository.literal(
        '熵',
        scope: scope,
        limitPerKind: 100,
      )).map((hit) => hit.identity).toSet(),
    );
  });

  test('空查询与没有命中时游标为空', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final repository = EvidenceRepository(db);

    final empty = await repository.searchBatch(
      '   ',
      scope: const EvidenceScope.userAll(),
    );
    expect(empty.hits, isEmpty);
    expect(empty.hasMore, isFalse);

    final none = await repository.searchBatch(
      '量子纠缠',
      scope: const EvidenceScope.userAll(),
    );
    expect(none.hits, isEmpty);
    expect(none.hasMore, isFalse);
  });
}
