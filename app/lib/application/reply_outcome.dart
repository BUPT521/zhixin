import '../ai/buddy_prompt.dart';

/// 模型回答收尾之后的正文、来源与中断情况。
class ReplyOutcome {
  const ReplyOutcome({
    required this.text,
    required this.fromModel,
    required this.stopped,
    required this.interrupted,
    required this.modelFailed,
    this.notice,
  });

  final String text;

  /// 正文是否来自模型；停止或中断时只有已经显示的部分算数。
  final bool fromModel;
  final bool stopped;
  final bool interrupted;

  /// 模型回答不可用，已退回本地规则。
  final bool modelFailed;
  final String? notice;
}

/// 把停止、生成中断与长度截断统一成界面要显示的结果。
///
/// 讨论与作答原先各写一份相同的判断与提示语，改其中一处时另一处仍按旧规则
/// 处理；两条路径现在都走这里，只有退回本地的正文与提示由调用方给出。
/// [localFallback] 只在模型给出中断却没有任何正文时调用。
ReplyOutcome interpretModelAnswer(
  BuddyReply answer, {
  required String? notice,
  required String Function() localFallback,
  required String fallbackNotice,
}) {
  if (answer.stopped) {
    final partial = answer.text.trim();
    if (partial.isEmpty) {
      return const ReplyOutcome(
        text: '已停止生成。',
        fromModel: false,
        stopped: true,
        interrupted: false,
        modelFailed: false,
        notice: '已停止生成。',
      );
    }
    return ReplyOutcome(
      text: partial,
      fromModel: true,
      stopped: true,
      interrupted: false,
      modelFailed: false,
      notice: '已停止生成，保留已经生成的部分。',
    );
  }
  if (answer.interrupted) {
    final partial = answer.text.trim();
    if (partial.isEmpty) {
      return ReplyOutcome(
        text: localFallback(),
        fromModel: false,
        stopped: false,
        interrupted: false,
        modelFailed: true,
        notice: _join(notice, fallbackNotice),
      );
    }
    return ReplyOutcome(
      text: partial,
      fromModel: true,
      stopped: false,
      interrupted: true,
      modelFailed: false,
      notice: _join(
        notice,
        '生成中断（${answer.interruptedReason ?? '连接中断'}），'
        '已保留已经生成的部分。',
      ),
    );
  }
  return ReplyOutcome(
    text: answer.text,
    fromModel: true,
    stopped: false,
    interrupted: false,
    modelFailed: false,
    notice: answer.truncated ? _join(notice, '回答被截断，已保留已经生成的部分。') : notice,
  );
}

String? _join(String? first, String second) =>
    first == null ? second : '$first $second';
