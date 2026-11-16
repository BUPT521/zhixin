import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/queries/evidence_scope.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/evidence_id.dart';
import 'package:zhixin/domain/models/score.dart';
import 'package:zhixin/domain/rules/embedding.dart';

import '../support/test_db.dart';

/// 范围预过滤的性质测试：预过滤只能放宽，不能收窄。
///
/// [hitInScope] 是范围规则的唯一实现，业务库按它判断一条命中是否还在范围内；
/// [vectorPrefilterFor] 在检索之前把范围下推到索引里。二者必须满足同一个方向：
/// 凡是 `hitInScope` 判为在范围内的来源，`vectorPrefilterFor` 必须放行，否则
/// 语义检索会漏掉本应出现的记录。反过来不要求成立：预过滤可以比业务规则宽，
/// 多出来的候选由业务库再核对。
///
/// 随机数据用固定种子，失败时可以直接复现；覆盖材料页、消息与作答三种语义
/// 来源，以及本机全部、一个目标、一份材料与回答前检索（有、无目标归属）等
/// 五种范围。
const _seed = 20261116;

/// 随机记录组数；每组都跑一遍下面的五种范围。
const _groups = 24;

EvidenceHit _pageHit(MaterialPageSeed page) => EvidenceHit(
  kind: EvidenceKind.materialPage,
  identity: EvidenceId.materialPage(page.materialId, page.pageNo).value,
  title: '材料页',
  snippet: page.content,
  matchedText: page.content,
  literal: false,
  score: Score.clamp(0.5),
  location: EvidenceLocation(materialId: page.materialId, pageNo: page.pageNo),
  sourceVersion: 'v1',
  text: page.content,
);

EvidenceHit _messageHit(MessageSeed message) => EvidenceHit(
  kind: EvidenceKind.message,
  identity: EvidenceId.message(message.id).value,
  title: '消息',
  snippet: message.content,
  matchedText: message.content,
  literal: false,
  score: Score.clamp(0.5),
  location: EvidenceLocation(
    conversationId: message.conversationId,
    messageId: message.id,
  ),
  sourceVersion: 'v1',
  text: message.content,
);

EvidenceHit _attemptHit(AttemptSeed attempt) => EvidenceHit(
  kind: EvidenceKind.answer,
  identity: EvidenceId.attempt(attempt.id).value,
  title: '作答',
  snippet: attempt.content,
  matchedText: attempt.content,
  literal: false,
  score: Score.clamp(0.5),
  location: EvidenceLocation(
    conversationId: attempt.conversationId,
    attemptId: attempt.id,
  ),
  sourceVersion: 'v1',
  text: attempt.content,
);

/// 命中对应的语义定位；与 `EvidenceRepository.semanticSources` 写入索引的
/// 来源键、讨论与材料归属保持一致。
SemanticLocator _locatorOf(EvidenceHit hit) {
  switch (hit.kind) {
    case EvidenceKind.materialPage:
      return SemanticLocator(
        kind: 'material_page',
        sourceKey: hit.identity,
        materialId: hit.location.materialId,
        pageNo: hit.location.pageNo,
      );
    case EvidenceKind.message:
      return SemanticLocator(
        kind: 'message',
        sourceKey: hit.identity,
        conversationId: hit.location.conversationId,
        messageId: hit.location.messageId,
      );
    case EvidenceKind.answer:
      return SemanticLocator(
        kind: 'answer',
        sourceKey: hit.identity,
        conversationId: hit.location.conversationId,
        attemptId: hit.location.attemptId,
      );
    case EvidenceKind.question:
    case EvidenceKind.unknown:
      throw StateError('题目与未知来源不是语义来源');
  }
}

class MaterialPageSeed {
  const MaterialPageSeed({
    required this.materialId,
    required this.pageNo,
    required this.content,
    required this.goalId,
  });

  final String materialId;
  final int pageNo;
  final String content;
  final String? goalId;
}

class MessageSeed {
  const MessageSeed({
    required this.id,
    required this.conversationId,
    required this.content,
  });

  final String id;
  final String conversationId;
  final String content;
}

class AttemptSeed {
  const AttemptSeed({
    required this.id,
    required this.conversationId,
    required this.content,
  });

  final String id;
  final String conversationId;
  final String content;
}

class _Fixture {
  _Fixture({
    required this.goals,
    required this.materialIds,
    required this.conversations,
    required this.pages,
    required this.messages,
    required this.attempts,
  });

  final List<String> goals;
  final List<String> materialIds;

  /// 讨论编号到目标归属；回答前检索按它判断无目标归属的讨论。
  final Map<String, String?> conversations;
  final List<MaterialPageSeed> pages;
  final List<MessageSeed> messages;
  final List<AttemptSeed> attempts;

  List<EvidenceHit> get hits => [
    for (final page in pages) _pageHit(page),
    for (final message in messages) _messageHit(message),
    for (final attempt in attempts) _attemptHit(attempt),
  ];

  /// 所有可以作为“本轮带入来源”的标识；只取语义来源。
  List<String> get identities => [for (final hit in hits) hit.identity];
}

Future<_Fixture> _seedFixture(RawDatabase raw, Random random) async {
  final tasks = TaskRepository(raw);
  final materials = MaterialRepository(raw);
  final conversations = ConversationRepository(raw);
  final attempts = AttemptRepository(raw);

  final goals = [
    for (var index = 0; index < 4; index++)
      await tasks.createGoal(title: '目标 $index'),
  ];
  String? randomGoal() =>
      random.nextBool() ? goals[random.nextInt(goals.length)] : null;

  final materialIds = <String>[];
  final pages = <MaterialPageSeed>[];
  for (var index = 0; index < 6; index++) {
    final goalId = randomGoal();
    final materialId = await materials.create(
      title: '材料 $index',
      goalId: goalId,
    );
    materialIds.add(materialId);
    final pageCount = 1 + random.nextInt(3);
    for (var pageNo = 1; pageNo <= pageCount; pageNo++) {
      final content = '第 $index 份材料第 $pageNo 页';
      await materials.addPage(
        materialId: materialId,
        pageNo: pageNo,
        content: content,
      );
      pages.add(
        MaterialPageSeed(
          materialId: materialId,
          pageNo: pageNo,
          content: content,
          goalId: goalId,
        ),
      );
    }
  }

  final conversationGoals = <String, String?>{};
  final messages = <MessageSeed>[];
  final attemptSeeds = <AttemptSeed>[];
  for (var index = 0; index < 8; index++) {
    final goalId = randomGoal();
    final useMaterial = random.nextBool();
    final materialId = useMaterial
        ? materialIds[random.nextInt(materialIds.length)]
        : null;
    final conversationId = await conversations.create(
      title: '讨论 $index',
      goalId: goalId,
      materialId: materialId,
      pageNo: materialId == null ? null : 1 + random.nextInt(2),
    );
    conversationGoals[conversationId] = goalId;
    final messageCount = 1 + random.nextInt(3);
    for (var turn = 0; turn < messageCount; turn++) {
      final message = await conversations.append(
        conversationId,
        role: turn.isEven ? MessageRole.user : MessageRole.assistant,
        content: '消息 $index-$turn',
      );
      messages.add(
        MessageSeed(
          id: message.id,
          conversationId: conversationId,
          content: message.content,
        ),
      );
    }
    if (random.nextBool()) {
      final attempt = await attempts.ensureOpenAttempt(conversationId);
      final content = '作答 $index';
      await attempts.submit(
        attempt.id,
        answer: content,
        isCorrect: random.nextBool(),
        independent: true,
      );
      attemptSeeds.add(
        AttemptSeed(
          id: attempt.id,
          conversationId: conversationId,
          content: content,
        ),
      );
    }
  }

  return _Fixture(
    goals: goals,
    materialIds: materialIds,
    conversations: conversationGoals,
    pages: pages,
    messages: messages,
    attempts: attemptSeeds,
  );
}

/// 一组随机范围：覆盖五种检索范围，范围的选择也从种子派生。
List<(String, EvidenceScope)> _scopes(_Fixture fixture, Random random) {
  String pickGoal() => fixture.goals[random.nextInt(fixture.goals.length)];
  String pickMaterial() =>
      fixture.materialIds[random.nextInt(fixture.materialIds.length)];
  String pickConversation() => fixture.conversations.keys.elementAt(
    random.nextInt(fixture.conversations.length),
  );

  final identities = fixture.identities;
  Set<String> randomBrought() {
    final count = random.nextInt(4);
    return {
      for (var index = 0; index < count; index++)
        identities[random.nextInt(identities.length)],
    };
  }

  return [
    ('本机全部记录', const EvidenceScope.userAll()),
    ('一个目标', EvidenceScope.userGoal(pickGoal())),
    ('一份材料', EvidenceScope.userMaterial(pickMaterial())),
    (
      '回答前无目标归属',
      EvidenceScope.answer(
        conversationId: pickConversation(),
        broughtIdentities: randomBrought(),
      ),
    ),
    (
      '回答前有目标归属',
      EvidenceScope.answer(
        goalId: pickGoal(),
        conversationId: random.nextBool() ? pickConversation() : null,
        broughtIdentities: randomBrought(),
      ),
    ),
  ];
}

void main() {
  test('凡 hitInScope 判为在范围内的来源，预过滤都必须放行', () async {
    final raw = await openTestDb();
    addTearDown(raw.close);
    final db = requireAppDatabase(raw);
    final random = Random(_seed);
    final fixture = await _seedFixture(raw, random);
    expect(fixture.hits, hasLength(greaterThan(20)));
    expect(fixture.pages, isNotEmpty);
    expect(fixture.messages, isNotEmpty);
    expect(fixture.attempts, isNotEmpty);

    final hits = fixture.hits;

    // 本机全部记录不附加条件：每条构造出来的命中都应该在范围内。先确认这一点，
    // 否则后面的“范围内”判断会被构造错误掩盖。
    for (final hit in hits) {
      expect(
        await hitInScope(db, hit, const EvidenceScope.userAll()),
        isTrue,
        reason: '构造的命中没有对应的业务记录：${hit.identity}',
      );
    }

    final checkedByScope = <String, int>{};
    for (var group = 0; group < _groups; group++) {
      final scopes = _scopes(fixture, random);
      for (final (label, scope) in scopes) {
        final prefilter = vectorPrefilterFor(scope);
        for (final hit in hits) {
          final inScope = await hitInScope(db, hit, scope);
          if (!inScope) continue;
          if (prefilter == null) continue;
          checkedByScope[label] = (checkedByScope[label] ?? 0) + 1;
          final locator = _locatorOf(hit);
          expect(
            prefilter.allows(locator),
            isTrue,
            reason:
                '范围「$label」放行了 ${hit.identity} 的命中，'
                '预过滤 ${prefilter.runtimeType} 却没有放行它',
          );
        }
      }
    }

    // 材料范围与回答前无目标范围都有可下推的预过滤，必须真的比较过候选，
    // 否则这组测试会变成空转。
    expect(checkedByScope['一份材料'], greaterThan(0));
    expect(checkedByScope['回答前无目标归属'], greaterThan(0));
  });

  test('回答前检索没有目标、当前讨论与带入来源时，预过滤一条也不放行', () async {
    final raw = await openTestDb();
    addTearDown(raw.close);
    final db = requireAppDatabase(raw);
    final random = Random(_seed + 1);
    final fixture = await _seedFixture(raw, random);
    const scope = EvidenceScope.answer();
    final prefilter = vectorPrefilterFor(scope);
    expect(prefilter, isNotNull);
    for (final hit in fixture.hits) {
      expect(await hitInScope(db, hit, scope), isFalse);
      expect(prefilter!.allows(_locatorOf(hit)), isFalse);
    }
  });

  test('材料范围只预过滤材料页，消息与作答仍然放行', () {
    final prefilter = vectorPrefilterFor(
      const EvidenceScope.userMaterial('material-1'),
    );
    expect(prefilter, isA<MaterialVectorPrefilter>());
    expect(
      prefilter!.allows(
        const SemanticLocator(
          kind: 'material_page',
          sourceKey: 'material_page:material-1:2',
          materialId: 'material-1',
          pageNo: 2,
        ),
      ),
      isTrue,
    );
    expect(
      prefilter.allows(
        const SemanticLocator(
          kind: 'material_page',
          sourceKey: 'material_page:material-2:1',
          materialId: 'material-2',
          pageNo: 1,
        ),
      ),
      isFalse,
    );
    expect(
      prefilter.allows(
        const SemanticLocator(
          kind: 'message',
          sourceKey: 'message:m-1',
          conversationId: 'c-1',
          messageId: 'm-1',
        ),
      ),
      isTrue,
    );
  });

  test('回答前无目标范围按当前讨论与本轮带入来源放行', () {
    final prefilter = vectorPrefilterFor(
      EvidenceScope.answer(
        conversationId: 'conversation-1',
        broughtIdentities: {
          EvidenceId.attempt('attempt-1').value,
          EvidenceId.materialPage('material-1', 3).value,
        },
      ),
    );
    expect(prefilter, isA<ConversationVectorPrefilter>());
    expect(
      prefilter!.allows(
        const SemanticLocator(
          kind: 'message',
          sourceKey: 'message:in-conversation',
          conversationId: 'conversation-1',
          messageId: 'in-conversation',
        ),
      ),
      isTrue,
    );
    expect(
      prefilter.allows(
        const SemanticLocator(
          kind: 'message',
          sourceKey: 'message:other',
          conversationId: 'conversation-2',
          messageId: 'other',
        ),
      ),
      isFalse,
    );
    expect(
      prefilter.allows(
        const SemanticLocator(
          kind: 'answer',
          sourceKey: 'attempt:attempt-1',
          conversationId: 'conversation-2',
          attemptId: 'attempt-1',
        ),
      ),
      isTrue,
    );
    expect(
      prefilter.allows(
        const SemanticLocator(
          kind: 'material_page',
          sourceKey: 'material_page:material-1:3',
          materialId: 'material-1',
          pageNo: 3,
        ),
      ),
      isTrue,
    );
    expect(
      prefilter.allows(
        const SemanticLocator(
          kind: 'material_page',
          sourceKey: 'material_page:material-2:1',
          materialId: 'material-2',
          pageNo: 1,
        ),
      ),
      isFalse,
    );
  });

  test('用户查找全部记录与一个目标时不下推预过滤', () {
    expect(vectorPrefilterFor(const EvidenceScope.userAll()), isNull);
    expect(vectorPrefilterFor(const EvidenceScope.userGoal('goal-1')), isNull);
    expect(
      vectorPrefilterFor(const EvidenceScope.answer(goalId: 'goal-1')),
      isNull,
      reason: '目标归属可以修改，写进索引会过期，只能在业务库核对',
    );
  });
}
