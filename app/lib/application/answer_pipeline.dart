import '../ai/ai_chat_service.dart';
import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/chat_message_payload.dart';
import 'answer_outcome.dart';
import 'buddy_answer.dart';
import 'service_runtime.dart';
import 'used_pages.dart';
import 'user_failure.dart';

/// 一次回答的收尾结果：模型原始结果、统一状态、可用性判断与本轮材料页。
class AnswerRun {
  const AnswerRun({
    required this.run,
    required this.outcome,
    required this.usedPages,
  });

  final BuddyAnswerRun run;
  final AnswerOutcome outcome;

  /// 本轮真正提供过的材料页；停止、中断与截断的回答同样记下，重试时接着用。
  final List<ChatUsedPage> usedPages;

  /// 模型给出的回答；没有可发送内容、配置读取失败或调用失败时为空。
  BuddyReply? get answer => run.answer;

  /// 模型回答完整可用：下一步建议、引用与记忆卡片只在可用时取。
  bool get usable => outcome.usable;
}

/// 走完一轮回答：调用模型、核对数据代次、收敛成统一状态并算出本轮材料页。
///
/// 讨论与作答原先各写一段收尾，判断条件已经分叉：讨论要求 `fromModel` 且没有
/// 截断，作答只查停止、中断与截断，还把 `modelFailed` 写死为假，`usedPages`
/// 的计算也逐字重复。三条路径（讨论、作答、系统学习）现在只有历史、图片与
/// 落库的差异，收尾状态一律从这里取。
///
/// [localFallback] 在模型没有给出回答，或给出中断却没有任何正文时调用。
Future<AnswerRun> runAnswer({
  required BuddyAi ai,
  required String Function() filesDir,
  required ServiceRuntime runtime,
  required int requestEpoch,
  required BuddyContext context,
  required List<ChatMessage> history,
  required String prompt,
  required String text,
  required List<String> imagePaths,
  String? inputMessageId,
  LlmConfig? config,
  void Function(String text)? onPartial,
  LlmCancelToken? cancelToken,
  required String Function() localFallback,
}) async {
  final run = await askBuddyModel(
    ai: ai,
    filesDir: filesDir,
    context: context,
    history: history,
    prompt: prompt,
    text: text,
    imagePaths: imagePaths,
    inputMessageId: inputMessageId,
    config: config,
    onPartial: onPartial,
    cancelToken: cancelToken,
    recordFailure: runtime.recordFailure,
  );
  // 等待模型期间可能发生了整库恢复或清空：迟到的回答不再写回新数据。
  ensureAnswerEpoch(runtime, requestEpoch);
  final answer = run.answer;
  final outcome = answer == null
      ? AnswerOutcome(
          text: localFallback(),
          fromModel: false,
          stopped: false,
          interrupted: false,
          modelFailed: run.modelFailed,
          notices: run.notices,
          omittedImages: run.omittedImages,
          failure: run.failure,
          quotaReason: run.quotaReason,
        )
      : interpretModelAnswer(
          answer,
          notices: run.notices,
          omittedImages: run.omittedImages,
          failure: run.failure,
          quotaReason: run.quotaReason,
          localFallback: localFallback,
        );
  return AnswerRun(
    run: run,
    outcome: outcome,
    usedPages: answer == null
        ? const <ChatUsedPage>[]
        : usedPagesOf(
            context,
            answer.providedSources,
            currentPage: context.materialPage?.pageKey,
          ),
  );
}

/// 回答路径共用的数据代次检查：整库恢复、导入或清空之后，旧请求不再写回。
///
/// 讨论、作答与系统学习原先各写一份，失败说明也各不相同；三处现在共用这一条，
/// 说明统一为“请重新打开这条记录后再试”。
void ensureAnswerEpoch(ServiceRuntime runtime, int expected) {
  if (runtime.dataEpoch != expected) {
    throw const UserFailure('数据已恢复或清空，请重新打开这条记录后再试。');
  }
}
