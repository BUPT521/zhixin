import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/reply_outcome.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';

void main() {
  String fallback() => '本地建议';

  test('停止生成保留已经显示的部分', () {
    final outcome = interpretModelAnswer(
      const BuddyReply(text: '先看定义', stopped: true),
      notice: '已准备题目图片。',
      localFallback: fallback,
      fallbackNotice: '模型调用失败，已切换为本地提示。',
    );

    expect(outcome.text, '先看定义');
    expect(outcome.fromModel, isTrue);
    expect(outcome.stopped, isTrue);
    expect(outcome.interrupted, isFalse);
    expect(outcome.notice, '已停止生成，保留已经生成的部分。');
  });

  test('还没有正文就停止时不把空回答当成模型结果', () {
    final outcome = interpretModelAnswer(
      const BuddyReply(text: '  ', stopped: true),
      notice: null,
      localFallback: fallback,
      fallbackNotice: '模型调用失败，已切换为本地提示。',
    );

    expect(outcome.text, '已停止生成。');
    expect(outcome.fromModel, isFalse);
    expect(outcome.notice, '已停止生成。');
  });

  test('中断且没有正文时退回本地，保留之前的说明', () {
    final outcome = interpretModelAnswer(
      const BuddyReply(text: '', interrupted: true),
      notice: '已准备题目图片。',
      localFallback: fallback,
      fallbackNotice: '模型调用失败，已切换为本地提示。',
    );

    expect(outcome.text, '本地建议');
    expect(outcome.fromModel, isFalse);
    expect(outcome.interrupted, isFalse);
    expect(outcome.modelFailed, isTrue);
    expect(outcome.notice, '已准备题目图片。 模型调用失败，已切换为本地提示。');
  });

  test('中断与截断都保留正文，并说明原因', () {
    final interrupted = interpretModelAnswer(
      const BuddyReply(
        text: '先看定义',
        interrupted: true,
        interruptedReason: '连接中断',
      ),
      notice: null,
      localFallback: fallback,
      fallbackNotice: '模型调用失败，已切换为本地提示。',
    );
    expect(interrupted.text, '先看定义');
    expect(interrupted.fromModel, isTrue);
    expect(interrupted.interrupted, isTrue);
    expect(interrupted.notice, '生成中断（连接中断），已保留已经生成的部分。');

    final truncated = interpretModelAnswer(
      const BuddyReply(text: '先看定义', truncated: true),
      notice: null,
      localFallback: fallback,
      fallbackNotice: '模型调用失败，已切换为本地提示。',
    );
    expect(truncated.text, '先看定义');
    expect(truncated.fromModel, isTrue);
    expect(truncated.notice, '回答被截断，已保留已经生成的部分。');
  });
}
