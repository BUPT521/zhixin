import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/answer_text.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';

import '../support/test_db.dart';

void main() {
  test('作答正文只拼接非空段，缺解答或反馈时不多出空行', () {
    expect(answerText('答案', '解答', '反馈'), '答案\n解答\n反馈');
    expect(answerText('答案', null, '反馈'), '答案\n反馈');
    expect(answerText('答案', '解答', null), '答案\n解答');
    expect(answerText('答案', '   ', null), '答案');
    expect(answerText(null, null, '反馈'), '反馈');
    expect(answerText('', '', ''), isEmpty);
    expect(answerText(null, null, null), isEmpty);
  });

  test('缺解答与反馈的作答在索引、核对与字面命中里是同一份正文与版本', () async {
    final db = await openTestDb();
    addTearDown(db.close);

    final conversations = ConversationRepository(db);
    final attempts = AttemptRepository(db);
    final evidence = EvidenceRepository(db);

    final conversationId = await conversations.create(title: '熵与时间');
    final attempt = await attempts.ensureOpenAttempt(conversationId);
    await attempts.submit(
      attempt.id,
      answer: '熵是状态函数，可逆过程才不变。',
      isCorrect: true,
      independent: true,
    );

    final sources = (await evidence.semanticSources()).where(
      (source) => source.locator.attemptId == attempt.id,
    );
    expect(sources, hasLength(1));
    final source = sources.single;
    expect(source.content, '熵是状态函数，可逆过程才不变。');

    // 写回前按定位与本机主键各读一次，两份正文与来源版本必须与索引时相同，
    // 否则索引里仍然有效的作答会被判成过期。
    final byLocator = await evidence.semanticSource(source.locator);
    expect(byLocator, isNotNull);
    expect(byLocator!.content, source.content);
    expect(byLocator.sourceVersion, source.sourceVersion);

    final byRow = await evidence.semanticSourceOfRow('attempt', attempt.id);
    expect(byRow, isNotNull);
    expect(byRow!.content, source.content);
    expect(byRow.sourceVersion, source.sourceVersion);

    final hits = await evidence.literal(
      '可逆过程',
      scope: const EvidenceScope.userAll(),
    );
    final answerHit = hits.singleWhere(
      (hit) => hit.kind == EvidenceKind.answer,
    );
    expect(answerHit.text, source.content);
    expect(answerHit.sourceVersion, source.sourceVersion);
    expect(answerHit.location.attemptId, attempt.id);
  });
}
