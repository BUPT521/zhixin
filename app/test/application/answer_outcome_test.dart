import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/answer_outcome.dart';
import 'package:zhixin/application/attachment_service.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';
import 'package:zhixin/domain/rules/notices.dart';

void main() {
  String fallback() => '本地建议';

  test('停止生成保留已经显示的部分，并记为用户停止', () {
    final outcome = interpretModelAnswer(
      const BuddyReply(text: '先看定义', stopped: true),
      localFallback: fallback,
    );

    expect(outcome.text, '先看定义');
    expect(outcome.fromModel, isTrue);
    expect(outcome.stopped, isTrue);
    expect(outcome.interrupted, isFalse);
    expect(outcome.notices, [Notice.userStopped]);
  });

  test('还没有正文就停止时不把空回答当成模型结果', () {
    final outcome = interpretModelAnswer(
      const BuddyReply(text: '  ', stopped: true),
      localFallback: fallback,
    );

    expect(outcome.text, '已停止生成。');
    expect(outcome.fromModel, isFalse);
    expect(outcome.notices, [Notice.userStopped]);
  });

  test('中断且没有正文时退回本地，并保留之前的提示状态', () {
    final outcome = interpretModelAnswer(
      const BuddyReply(text: '', interrupted: true),
      notices: const [Notice.imagesUnavailable],
      omittedImages: const [AttachmentOmissionReason.uploadDisabled],
      localFallback: fallback,
    );

    expect(outcome.text, '本地建议');
    expect(outcome.fromModel, isFalse);
    expect(outcome.interrupted, isFalse);
    expect(outcome.modelFailed, isTrue);
    expect(outcome.notices, [Notice.imagesUnavailable, Notice.modelCallFailed]);
    expect(outcome.omittedImages, [AttachmentOmissionReason.uploadDisabled]);
  });

  test('中断保留正文并给出中断原因，截断保留正文并记为被截断', () {
    final interrupted = interpretModelAnswer(
      const BuddyReply(
        text: '先看定义',
        interrupted: true,
        interruptedReason: '连接中断',
      ),
      localFallback: fallback,
    );
    expect(interrupted.text, '先看定义');
    expect(interrupted.fromModel, isTrue);
    expect(interrupted.interrupted, isTrue);
    expect(interrupted.notices, [Notice.generationInterrupted]);
    expect(interrupted.detail, '连接中断');

    final truncated = interpretModelAnswer(
      const BuddyReply(text: '先看定义', truncated: true),
      localFallback: fallback,
    );
    expect(truncated.text, '先看定义');
    expect(truncated.fromModel, isTrue);
    expect(truncated.notices, [Notice.answerTruncated]);
  });
}
