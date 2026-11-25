import '../ai/ai_chat_service.dart';
import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../domain/models/chat_message.dart';
import '../domain/rules/notices.dart';
import 'attachment_service.dart';
import 'service_runtime.dart';

/// 读配置、备图并调用模型之后的结果。
///
/// 状态由 [notices] 给出，界面按枚举写说明；不再用提示文案的子串判断这次
/// 能不能重试、要不要去设置。
class BuddyAnswerRun {
  const BuddyAnswerRun({
    required this.config,
    required this.answer,
    this.notices = const [],
    this.omittedImages = const [],
    this.failure,
    this.notSent = false,
  });

  final LlmConfig? config;

  /// 模型给出的回答；没有可发送的内容、调用失败或模型没配置好时为空。
  final BuddyReply? answer;

  /// 配置读取、图片准备与调用失败合成的情况。
  final List<Notice> notices;

  /// 没有发送的图片原因。
  final List<AttachmentOmissionReason> omittedImages;

  /// 调用失败的类型；配置读取失败与没有可发送内容时为空。
  final LlmFailure? failure;

  /// 没有可发送的内容，本次没有调用模型。
  final bool notSent;

  /// 模型已经配置、调用失败；界面据此给出重试入口。
  bool get modelFailed => notices.contains(Notice.modelCallFailed);
}

/// 读取模型配置；读取失败按“未配置”处理，并给出统一的状态。
///
/// 讨论、作答、系统学习与重答原先各自 catch 配置读取失败，有的按未配置处理、
/// 有的把异常抛给界面；现在从这一处取，失败一律落成未配置与同一条状态。
Future<({LlmConfig? config, List<Notice> notices})> readModelConfig(
  BuddyAi ai, {
  ModelFailureRecorder? recordFailure,
}) async {
  final read = await ai.config();
  final failure = read.failureOrNull;
  if (failure != null) {
    recordFailure?.call(failure, StackTrace.current, kind: 'model_config_read');
    return (config: null, notices: const [Notice.modelConfigReadFailed]);
  }
  return (config: read.valueOrNull, notices: const <Notice>[]);
}

Future<BuddyAnswerRun> askBuddyModel({
  required BuddyAi ai,
  required String Function() filesDir,
  required BuddyContext context,
  required List<ChatMessage> history,
  required String prompt,
  required String text,
  required List<String> imagePaths,
  String? inputMessageId,
  LlmConfig? config,
  void Function(String text)? onPartial,
  LlmCancelToken? cancelToken,
  ModelFailureRecorder? recordFailure,
}) async {
  var current = config;
  var notices = <Notice>[];
  if (current == null) {
    final read = await readModelConfig(ai, recordFailure: recordFailure);
    current = read.config;
    notices.addAll(read.notices);
  }
  final prepared = await AttachmentService(filesDir: filesDir)
      .prepare(imagePaths, enabled: current?.allowImages ?? false);
  if (prepared.omitted.isNotEmpty) notices.add(Notice.imagesUnavailable);
  final modelReady = current?.isConfigured ?? false;

  // 有图但一张都发不出去、又没有文字时没有可问的内容，不调用模型。
  if (prepared.images.isEmpty && text.trim().isEmpty) {
    if (!modelReady && !notices.contains(Notice.modelConfigReadFailed)) {
      notices.add(Notice.modelNotConfigured);
    }
    notices.add(Notice.noSendableContent);
    return BuddyAnswerRun(
      config: current,
      answer: null,
      notices: notices,
      omittedImages: prepared.omitted,
      notSent: true,
    );
  }

  try {
    final answer = await ai.ask(
      context: context,
      history: history,
      text: prompt,
      inputMessageId: inputMessageId,
      images: prepared.images,
      onText: onPartial,
      cancelToken: cancelToken,
      configSnapshot: LlmConfigSnapshot(current),
    );
    return BuddyAnswerRun(
      config: current,
      answer: answer,
      notices: notices,
      omittedImages: prepared.omitted,
    );
  } on LlmException catch (error, stack) {
    // 取消是用户自己停下的，不算需要排障的失败。
    if (error.failure != LlmFailure.cancelled) {
      recordFailure?.call(error, stack, kind: 'model_call');
    }
    if (error.failure != LlmFailure.notConfigured) {
      notices.add(Notice.modelCallFailed);
    } else if (!notices.contains(Notice.modelConfigReadFailed)) {
      notices.add(Notice.modelNotConfigured);
    }
    return BuddyAnswerRun(
      config: current,
      answer: null,
      notices: notices,
      omittedImages: prepared.omitted,
      failure: error.failure,
    );
  } catch (error, stack) {
    recordFailure?.call(error, stack, kind: 'model_call');
    notices.add(Notice.modelCallFailed);
    return BuddyAnswerRun(
      config: current,
      answer: null,
      notices: notices,
      omittedImages: prepared.omitted,
      failure: LlmFailure.unknown,
    );
  }
}
