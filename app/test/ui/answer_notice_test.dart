import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/application/answer_outcome.dart';
import 'package:zhixin/application/attachment_service.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
import 'package:zhixin/domain/rules/notices.dart';
import 'package:zhixin/ui/answer_notice.dart';

void main() {
  AnswerOutcome outcome({
    List<Notice> notices = const [],
    String? detail,
    List<AttachmentOmissionReason> omittedImages = const [],
    LlmFailure? failure,
    QuotaExhaustedReason? quotaReason,
    bool fromModel = false,
  }) => AnswerOutcome(
    text: '',
    fromModel: fromModel,
    stopped: false,
    interrupted: false,
    modelFailed: failure != null,
    notices: notices,
    detail: detail,
    omittedImages: omittedImages,
    failure: failure,
    quotaReason: quotaReason,
  );

  test('模型调用失败按失败类型写原因与下一步', () {
    final text = answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.auth,
      ),
    );
    expect(
      text,
      '模型调用失败（登录已失效或没有访问权限），已切换为本地规则回答；'
      '问题与本地回答会保存在本机。'
      '请先登录并确认模型名在服务端允许的列表里，改好后再点「重试这次回答」。',
    );

    final offline = answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.offline,
      ),
    );
    expect(offline, contains('检查网络后可以点「重试这次回答」。'));
  });

  test('额度用完按原因给出购买入口，实例预算用完只让稍后再试', () {
    String quotaText(QuotaExhaustedReason? reason) => answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.quotaExhausted,
        quotaReason: reason,
      ),
    )!;

    final account = quotaText(QuotaExhaustedReason.account);
    expect(account, contains('今日免费额度已经用完'));
    expect(account, contains('购买积分'));
    expect(account, contains('等次日恢复'));
    expect(account, contains('再点「重试这次回答」。'));

    final points = quotaText(QuotaExhaustedReason.points);
    expect(points, contains('积分不足'));
    expect(points, contains('购买积分'));
    expect(points, isNot(contains('等次日恢复')));
    expect(points, contains('再点「重试这次回答」。'));

    // 实例预算用完与旧版服务端没有原因时，购买积分不能解决问题，不写购买入口。
    for (final reason in [QuotaExhaustedReason.instance, null]) {
      final text = quotaText(reason);
      expect(text, contains('模型服务今天的额度已经用完'));
      expect(text, contains('稍后再点「重试这次回答」。'));
      expect(text, isNot(contains('购买积分')));
    }
  });

  test('余额副本正在同步时只让稍后重试，不给购买入口', () {
    final text = answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.quotaExhausted,
        quotaReason: QuotaExhaustedReason.syncing,
      ),
    )!;
    expect(text, contains('积分余额正在同步'));
    expect(text, contains('稍后重试'));
    expect(text, isNot(contains('购买')));
    expect(text, isNot(contains('等次日恢复')));
  });

  test('短时繁忙与额度用完给出不同的下一步', () {
    final busy = answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.busy,
      ),
    );
    expect(busy, contains('模型服务暂时繁忙'));
    expect(busy, contains('等一会儿再点「重试这次回答」。'));
    expect(busy, isNot(contains('额度已经用完')));

    final quota = answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.quotaExhausted,
      ),
    );
    expect(quota, contains('模型服务今天的额度已经用完'));
  });

  test('未知失败不带原因括号，也没有重试以外的说法', () {
    final text = answerNoticeText(
      outcome(
        notices: const [Notice.modelCallFailed],
        failure: LlmFailure.unknown,
      ),
    );
    expect(
      text,
      '模型调用失败，已切换为本地规则回答；问题与本地回答会保存在本机。'
      '可以点「重试这次回答」。',
    );
  });

  test('模型不可用时写明要先登录，没有可发送内容时只讲一遍', () {
    expect(
      answerNoticeText(outcome(notices: const [Notice.modelNotConfigured])),
      '还没有登录知新服务，这次先用本地规则回答；问题与本地回答会保存在本机。'
      '登录之后回到这里重新回答。',
    );
    expect(
      answerNoticeText(
        outcome(
          notices: const [Notice.modelNotConfigured, Notice.noSendableContent],
        ),
      ),
      '还没有登录知新服务，图片没有发送；题目与已写内容仍在本机。登录后可以重新回答。',
    );
    expect(
      answerNoticeText(outcome(notices: const [Notice.noSendableContent])),
      '本次没有可发送的图片，未调用模型；题目与已写内容仍在本机。'
      '可以换一张可读取的图片，或补充文字后再试。',
    );
  });

  test('没有发送的图片按原因列出，顺序稳定', () {
    final text = answerNoticeText(
      outcome(
        notices: const [Notice.imagesUnavailable],
        omittedImages: const [
          AttachmentOmissionReason.tooMany,
          AttachmentOmissionReason.tooLarge,
        ],
      ),
    );
    expect(text, '超过两张的图片未发送；超过 4 MB 的图片未发送。');
  });

  test('停止、截断与中断各自说明保留了哪些正文', () {
    expect(
      answerNoticeText(outcome(notices: const [Notice.userStopped])),
      '已停止生成。',
    );
    expect(
      answerNoticeText(
        outcome(notices: const [Notice.userStopped], fromModel: true),
      ),
      '已停止生成，保留已经生成的部分。',
    );
    expect(
      answerNoticeText(outcome(notices: const [Notice.answerTruncated])),
      '回答被截断，已保留已经生成的部分。',
    );
    expect(
      answerNoticeText(
        outcome(notices: const [Notice.generationInterrupted], detail: '连接中断'),
      ),
      '生成中断（连接中断），已保留已经生成的部分。',
    );
  });

  test('多条提示按顺序用空格连接，记忆保存失败单独一句', () {
    final text = answerNoticeText(
      outcome(
        notices: const [Notice.imagesUnavailable, Notice.memorySaveFailed],
        omittedImages: const [AttachmentOmissionReason.uploadDisabled],
      ),
    );
    expect(text, '图片上传已关闭。 记忆保存失败，回答已保存。');
  });

  test('重新打开讨论时按保存下来的值与失败类型写回同一条说明', () {
    final message = ChatMessage(
      id: 'msg-1',
      conversationId: 'conv-1',
      role: MessageRole.assistant,
      content: '本地回答',
      payload: const ChatMessagePayload(
        fromModel: false,
        modelFailed: true,
        failureName: 'auth',
        notices: [Notice.modelCallFailed],
      ),
    );
    final saved = savedAnswerStatus(message);
    expect(saved.notices, [Notice.modelCallFailed]);
    expect(saved.failure, LlmFailure.auth);
    expect(saved.needsConfig, isFalse);
    expect(savedAnswerNoticeText(saved), contains('登录已失效或没有访问权限'));
  });

  test('重新打开讨论时保留额度用完的原因，说明与当时一致', () {
    final message = ChatMessage(
      id: 'msg-1',
      conversationId: 'conv-1',
      role: MessageRole.assistant,
      content: '本地回答',
      payload: const ChatMessagePayload(
        fromModel: false,
        modelFailed: true,
        failureName: 'quotaExhausted',
        quotaReason: 'points',
        notices: [Notice.modelCallFailed],
      ),
    );
    final saved = savedAnswerStatus(message);
    expect(saved.failure, LlmFailure.quotaExhausted);
    expect(saved.quotaReason, QuotaExhaustedReason.points);
    expect(savedAnswerNoticeText(saved), contains('积分不足，可以在账号页购买积分'));
  });

  test('旧消息里存成 rateLimited 的失败按额度用完读回', () {
    final message = ChatMessage(
      id: 'msg-1',
      conversationId: 'conv-1',
      role: MessageRole.assistant,
      content: '本地回答',
      payload: const ChatMessagePayload(
        fromModel: false,
        modelFailed: true,
        failureName: 'rateLimited',
        notices: [Notice.modelCallFailed],
      ),
    );
    final saved = savedAnswerStatus(message);
    expect(saved.failure, LlmFailure.quotaExhausted);
    expect(savedAnswerNoticeText(saved), contains('模型服务今天的额度已经用完'));
  });

  test('本地兜底中模型不可用的消息需要登录入口', () {
    final message = ChatMessage(
      id: 'msg-1',
      conversationId: 'conv-1',
      role: MessageRole.assistant,
      content: '本地回答',
      payload: const ChatMessagePayload(
        fromModel: false,
        notices: [Notice.modelNotConfigured],
      ),
    );
    final saved = savedAnswerStatus(message);
    expect(saved.needsConfig, isTrue);
    expect(saved.failure, isNull);
  });
}
