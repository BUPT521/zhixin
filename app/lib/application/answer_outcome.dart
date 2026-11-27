import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../domain/models/chat_message.dart';
import '../domain/rules/notices.dart';
import 'attachment_service.dart';

/// 一次回答收尾之后的正文、来源与中断情况；讨论与作答的最终结果都用它。
///
/// 收尾状态由 [notices] 给出，界面按枚举写说明；[detail] 只转达具体原因
/// （例如生成中断的原因），不参与状态判断。
class AnswerOutcome {
  const AnswerOutcome({
    required this.text,
    required this.fromModel,
    required this.stopped,
    required this.interrupted,
    required this.modelFailed,
    this.notices = const [],
    this.detail,
    this.omittedImages = const [],
    this.failure,
    this.quotaReason,
  });

  final String text;

  /// 正文是否来自模型；停止或中断时只有已经显示的部分算数。
  final bool fromModel;
  final bool stopped;
  final bool interrupted;

  /// 模型回答不可用，已退回本地规则。
  final bool modelFailed;

  /// 这次回答需要界面区分的情况。
  final List<Notice> notices;

  /// 生成中断的原因等具体补充；句子由界面写。
  final String? detail;

  /// 没有发送的图片原因。
  final List<AttachmentOmissionReason> omittedImages;

  /// 模型调用失败的类型；界面据此决定下一步说法。
  final LlmFailure? failure;

  /// 额度用完的具体原因；只有 [LlmFailure.quotaExhausted] 时可能非空。
  final QuotaExhaustedReason? quotaReason;

  /// 模型回答是否完整可用：正文来自模型、没有停止、没有中断、没有被截断。
  ///
  /// 讨论取下一步建议、引用与记忆卡片，作答取记忆建议，原先各写一份判断
  /// （作答漏了 `fromModel`，还把 `modelFailed` 写死为假）；两处现在都读这一项。
  bool get usable => fromModel && !stopped && !interrupted && !truncated;

  /// 回答被长度截断；收尾提示里已经写明。
  bool get truncated => notices.contains(Notice.answerTruncated);

  /// 换掉正文或提示状态，其余收尾状态照旧。
  AnswerOutcome copyWith({String? text, List<Notice>? notices}) =>
      AnswerOutcome(
        text: text ?? this.text,
        fromModel: fromModel,
        stopped: stopped,
        interrupted: interrupted,
        modelFailed: modelFailed,
        notices: notices ?? this.notices,
        detail: detail,
        omittedImages: omittedImages,
        failure: failure,
        quotaReason: quotaReason,
      );
}

/// 把停止、生成中断与长度截断统一成界面要显示的结果。
///
/// 讨论与作答原先各写一份相同的判断与提示语，改其中一处时另一处仍按旧规则
/// 处理；两条路径现在都走这里，只有退回本地的正文与之前的状态由调用方给出。
/// [localFallback] 只在模型给出中断却没有任何正文时调用。
AnswerOutcome interpretModelAnswer(
  BuddyReply answer, {
  List<Notice> notices = const [],
  List<AttachmentOmissionReason> omittedImages = const [],
  LlmFailure? failure,
  QuotaExhaustedReason? quotaReason,
  required String Function() localFallback,
}) {
  if (answer.stopped) {
    final partial = answer.text.trim();
    return AnswerOutcome(
      text: partial.isEmpty ? '已停止生成。' : partial,
      fromModel: partial.isNotEmpty,
      stopped: true,
      interrupted: false,
      modelFailed: false,
      notices: [...notices, Notice.userStopped],
      omittedImages: omittedImages,
      failure: failure,
      quotaReason: quotaReason,
    );
  }
  if (answer.interrupted) {
    final partial = answer.text.trim();
    if (partial.isEmpty) {
      return AnswerOutcome(
        text: localFallback(),
        fromModel: false,
        stopped: false,
        interrupted: false,
        modelFailed: true,
        notices: [...notices, Notice.modelCallFailed],
        omittedImages: omittedImages,
        failure: failure,
        quotaReason: quotaReason,
      );
    }
    return AnswerOutcome(
      text: partial,
      fromModel: true,
      stopped: false,
      interrupted: true,
      modelFailed: false,
      notices: [...notices, Notice.generationInterrupted],
      detail: answer.interruptedReason,
      omittedImages: omittedImages,
      failure: failure,
      quotaReason: quotaReason,
    );
  }
  return AnswerOutcome(
    text: answer.text,
    fromModel: true,
    stopped: false,
    interrupted: false,
    modelFailed: false,
    notices: answer.truncated ? [...notices, Notice.answerTruncated] : notices,
    omittedImages: omittedImages,
    failure: failure,
    quotaReason: quotaReason,
  );
}

/// 已经保存的一条回答在重新打开时要恢复的提示状态。
class SavedAnswerStatus {
  const SavedAnswerStatus({
    this.notices = const [],
    this.failure,
    this.quotaReason,
  });

  final List<Notice> notices;
  final LlmFailure? failure;

  /// 额度用完的具体原因；旧消息没有这一项时为空，界面按通用额度用完处理。
  final QuotaExhaustedReason? quotaReason;

  /// 这次回答因为在设置里补配置就能继续，界面给配置入口而不是重试入口。
  bool get needsConfig =>
      notices.contains(Notice.modelNotConfigured) ||
      notices.contains(Notice.modelConfigReadFailed);
}

/// 从回答消息的结构化字段读回提示状态；没有这一项的回答返回空状态。
SavedAnswerStatus savedAnswerStatus(ChatMessage message) {
  final payload = message.payload;
  return SavedAnswerStatus(
    notices: payload?.notices ?? const [],
    failure: llmFailureFromName(payload?.failureName),
    quotaReason: QuotaExhaustedReason.fromName(payload?.quotaReason),
  );
}
