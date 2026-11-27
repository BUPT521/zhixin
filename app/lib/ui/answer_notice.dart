import '../ai/llm_client.dart';
import '../application/answer_outcome.dart';
import '../application/attachment_service.dart';
import '../application/buddy_actions.dart';
import '../domain/rules/notices.dart';

/// 把回答收尾说明与这次没有保存的记忆并成一条：回答的情况在前，跳过的记忆在后。
///
/// 超长的记忆卡片仍留在回答下面，用户点“记下”时确认入口再给一次同样的说明；
/// 发送后先在提示里说清哪一条没有保存，避免同一句话只在点击后才出现。
String? mergeAnswerNotice(String? notice, Iterable<MemorySkip> skipped) {
  final parts = <String>[
    if (notice != null && notice.trim().isNotEmpty) notice.trim(),
    for (final skip in skipped) skip.message,
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

/// 把回答收尾的提示状态写成界面说明。
///
/// 状态判断只用枚举与失败类型，句子只在这里定；应用层转达的具体原因
/// （[AnswerOutcome.detail]）只补进对应句子，不参与判断。
String? answerNoticeText(AnswerOutcome outcome) => _noticeText(
  notices: outcome.notices,
  failure: outcome.failure,
  quotaReason: outcome.quotaReason,
  detail: outcome.detail,
  omittedImages: outcome.omittedImages,
  keptPartial: outcome.fromModel,
);

/// 重新打开讨论时，按保存下来的提示状态写同一条说明。
String? savedAnswerNoticeText(
  SavedAnswerStatus status, {
  bool keptPartial = false,
}) => _noticeText(
  notices: status.notices,
  failure: status.failure,
  quotaReason: status.quotaReason,
  keptPartial: keptPartial,
);

String? _noticeText({
  required List<Notice> notices,
  LlmFailure? failure,
  QuotaExhaustedReason? quotaReason,
  String? detail,
  List<AttachmentOmissionReason> omittedImages = const [],
  bool keptPartial = false,
}) {
  final context = _NoticeContext(
    notices: notices,
    failure: failure,
    quotaReason: quotaReason,
    detail: detail,
    omittedImages: omittedImages,
    keptPartial: keptPartial,
  );
  final sentences = <String>[
    for (final notice in notices) ?_sentenceOf(notice, context),
  ];
  return sentences.isEmpty ? null : sentences.join(' ');
}

class _NoticeContext {
  const _NoticeContext({
    required this.notices,
    required this.failure,
    required this.quotaReason,
    required this.detail,
    required this.omittedImages,
    required this.keptPartial,
  });

  final List<Notice> notices;
  final LlmFailure? failure;
  final QuotaExhaustedReason? quotaReason;
  final String? detail;
  final List<AttachmentOmissionReason> omittedImages;
  final bool keptPartial;

  bool has(Notice notice) => notices.contains(notice);
}

String? _sentenceOf(Notice notice, _NoticeContext context) {
  switch (notice) {
    case Notice.modelConfigReadFailed:
      return '模型配置读取失败，这次先用本地规则回答；问题与本地回答会保存在本机。'
          '可以在设置的开发者模式中重新保存模型配置。';
    case Notice.modelNotConfigured:
      // 没有可发送内容时由下一句一并说明，不重复讲一遍模型未配置。
      if (context.has(Notice.noSendableContent)) return null;
      return '还没有登录知新服务，这次先用本地规则回答；问题与本地回答会保存在本机。'
          '登录之后回到这里重新回答。';
    case Notice.noSendableContent:
      return context.has(Notice.modelNotConfigured)
          ? '还没有登录知新服务，图片没有发送；题目与已写内容仍在本机。登录后可以重新回答。'
          : '本次没有可发送的图片，未调用模型；题目与已写内容仍在本机。'
                '可以换一张可读取的图片，或补充文字后再试。';
    case Notice.imagesUnavailable:
      return _omittedImagesText(context.omittedImages);
    case Notice.modelCallFailed:
      return '模型调用失败${_failureSuffix(context.failure)}，已切换为本地规则回答；'
          '问题与本地回答会保存在本机。'
          '${_modelNextStep(context.failure, context.quotaReason)}';
    case Notice.answerTruncated:
      return '回答被截断，已保留已经生成的部分。';
    case Notice.userStopped:
      return context.keptPartial ? '已停止生成，保留已经生成的部分。' : '已停止生成。';
    case Notice.generationInterrupted:
      return '生成中断（${context.detail ?? '连接中断'}），已保留已经生成的部分。';
    case Notice.memorySaveFailed:
      return '记忆保存失败，回答已保存。';
  }
}

String _failureSuffix(LlmFailure? failure) =>
    failure == null || failure == LlmFailure.unknown
    ? ''
    : '（${shortTextOf(failure)}）';

/// 模型失败之后重新回答的下一步；按失败类型给，不重复读异常原文。
///
/// 额度用完再按具体原因分开：账号免费额度与积分不足都有购买积分的价值，实例预算
/// 用完与余额副本同步中只能等恢复，因此这几种不给购买入口。
String _modelNextStep(LlmFailure? failure, QuotaExhaustedReason? quotaReason) =>
    switch (failure) {
      LlmFailure.auth => '请先登录并确认模型名在服务端允许的列表里，改好后再点「重试这次回答」。',
      LlmFailure.contactUnverified =>
        '先在账号页确认一种登录方式，确认后才能使用知新服务的托管额度，改好后再点「重试这次回答」。',
      LlmFailure.offline || LlmFailure.timeout => '检查网络后可以点「重试这次回答」。',
      LlmFailure.busy => '模型服务刚才很忙，等一会儿再点「重试这次回答」。',
      LlmFailure.quotaExhausted => switch (quotaReason) {
        QuotaExhaustedReason.account =>
          '今日免费额度已经用完，可以在账号页购买积分之后继续，也可以等次日恢复，'
              '再点「重试这次回答」。',
        QuotaExhaustedReason.points => '积分不足，可以在账号页购买积分之后继续，再点「重试这次回答」。',
        QuotaExhaustedReason.syncing => '积分余额正在同步，请稍后重试，再点「重试这次回答」。',
        QuotaExhaustedReason.instance || null => '模型服务今天的额度已经用完，稍后再点「重试这次回答」。',
      },
      LlmFailure.contextLimit => '可以缩短问题、减少图片，或在开发者模式中核对模型上下文上限。',
      LlmFailure.modelNotAllowed => '请在设置的开发者模式中选择当前实例已启用的聊天模型，再重试这次回答。',
      LlmFailure.badResponse ||
      LlmFailure.toolUnsupported => '请检查设置里的模型名，改好后再点「重试这次回答」。',
      _ => '可以点「重试这次回答」。',
    };

String _omittedImagesText(List<AttachmentOmissionReason> reasons) {
  if (reasons.isEmpty) return '本次有图片没有发送。';
  final distinct = reasons.toSet().toList()
    ..sort((left, right) => left.index.compareTo(right.index));
  return '${distinct.map(_omittedImageLabel).join('；')}。';
}

String _omittedImageLabel(AttachmentOmissionReason reason) => switch (reason) {
  AttachmentOmissionReason.uploadDisabled => '图片上传已关闭',
  AttachmentOmissionReason.tooMany => '超过两张的图片未发送',
  AttachmentOmissionReason.missing => '部分图片文件已找不到',
  AttachmentOmissionReason.tooLarge => '超过 4 MB 的图片未发送',
  AttachmentOmissionReason.unreadable => '部分图片无法读取',
};
