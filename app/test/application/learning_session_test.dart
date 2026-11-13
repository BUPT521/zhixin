import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/learning_service.dart';
import 'package:zhixin/domain/models/question.dart';

Attempt _attempt(
  int id, {
  bool? correct,
  String? feedback,
  bool submitted = true,
}) {
  return Attempt(
    id: id,
    conversationId: 1,
    isCorrect: correct,
    feedback: feedback,
    submittedAt: submitted ? DateTime(2026, 11, 7, 20, id) : null,
  );
}

void main() {
  test('场次结果按最新的已提交尝试推出', () {
    expect(deriveSessionOutcome(const []), isNull);
    expect(deriveSessionOutcome([_attempt(1, submitted: false)]), isNull);
    expect(deriveSessionOutcome([_attempt(1, correct: true)]), 'done');
    expect(
      deriveSessionOutcome([
        _attempt(2, correct: false),
        _attempt(1, correct: true),
      ]),
      'partial',
    );
    expect(
      deriveSessionOutcome([
        _attempt(2, correct: false),
        _attempt(1, correct: false),
      ]),
      'not_done',
    );
  });

  test('未提交的尝试不参与结果，最新的提交以编号为准', () {
    expect(
      deriveSessionOutcome([
        _attempt(3, submitted: false),
        _attempt(2, correct: true),
        _attempt(1, correct: false),
      ]),
      'done',
    );
  });

  test('暂不判断的作答不推出结果，也不当成答错', () {
    expect(
      deriveSessionOutcome([_attempt(2), _attempt(1, correct: false)]),
      'not_done',
    );
    expect(deriveSessionOutcome([_attempt(1)]), isNull);
    expect(
      deriveSessionOutcome([_attempt(2), _attempt(1, correct: true)]),
      'done',
    );
  });

  test('摘要取最新的困难，跳过空内容', () {
    expect(deriveSessionSummary(const []), isNull);
    expect(
      deriveSessionSummary([
        _attempt(3, correct: true),
        _attempt(2, correct: false, feedback: '放缩方向还不确定'),
        _attempt(1, correct: false, feedback: '更早的卡点'),
      ]),
      '放缩方向还不确定',
    );
  });
}
