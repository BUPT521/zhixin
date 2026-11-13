import '../ai/ai_chat_service.dart';
import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../domain/models/chat_message.dart';
import 'attachment_service.dart';
import 'service_runtime.dart';

/// 退回本地规则回答时的统一说明。
///
/// 讨论发送与作答求助原先各写一句，措辞还不一样（“本地规则回答”与
/// “本地提示”），改一处时另一处仍按旧说法提示；两条路径现在都从这里取。
/// 说明同时交代已经保留下来的内容与下一步，用户不必到别处确认这一轮是否还能
/// 重试。
const String modelFallbackNotice =
    '模型调用失败，已切换为本地规则回答；问题与本地回答会保存在本机。'
    '可以点「重试这次回答」。';

/// 读配置、备图并调用模型之后的结果。
class BuddyAnswerRun {
  const BuddyAnswerRun({
    required this.config,
    required this.answer,
    required this.notice,
    required this.modelMissing,
    required this.modelFailed,
    required this.notSent,
    this.failure,
  });

  final LlmConfig? config;

  /// 模型给出的回答；没有可发送的内容、调用失败或模型没配置好时为空。
  final BuddyReply? answer;

  /// 配置读取、图片准备与调用失败合成的一条提示。
  final String? notice;

  /// 模型没有配置好：没有配置项，或配置读取失败。本地回答据此说明原因。
  final bool modelMissing;

  /// 模型已经配置、调用失败；界面据此给出重试入口。
  final bool modelFailed;

  /// 没有可发送的内容，本次没有调用模型。
  final bool notSent;

  /// 调用失败的类型；配置读取失败与没有可发送内容时为空。
  final LlmFailure? failure;
}

/// 读配置、备图并调用模型；讨论发送与作答求助共用这一份。
///
/// 讨论与作答原先各写一段读配置、备图、调用与失败提示，改其中一处时另一处
/// 仍按旧规则处理；两条路径现在只在这里决定发送什么、失败时说什么。
/// [text] 是用户这次自己写下的内容，图片都不可发送时用它判断是否还有事可做；
/// [prompt] 是真正发给模型的文字，作答求助发的是按模式拼好的问题。
/// [config] 是调用方已经读到的配置：重答要在写入任何内容之前先判断模型是否
/// 配置好，已经读过一次，这里直接复用，不再读第二次；传空表示没有读过，由
/// 这里读取，读取失败时按未配置处理。
/// [recordFailure] 只把类型、消息与调用栈交给本机诊断记录，不参与界面说明。
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
  String? notice;
  if (current == null) {
    try {
      current = await ai.config();
    } catch (error, stack) {
      recordFailure?.call(error, stack, kind: 'model_config_read');
      notice =
          '模型配置读取失败，这次先用本地规则回答；问题与本地回答会保存在本机。'
          '可以到设置里重新保存一次模型配置。';
    }
  }
  final prepared = await AttachmentService(filesDir: filesDir)
      .prepare(imagePaths, enabled: current?.allowImages ?? false);
  notice = _joinNotices(notice, prepared.notice);
  final modelReady = current?.isConfigured ?? false;

  // 有图但一张都发不出去、又没有文字时没有可问的内容，不调用模型。
  if (prepared.images.isEmpty && text.trim().isEmpty) {
    return BuddyAnswerRun(
      config: current,
      answer: null,
      notice: _joinNotices(
        notice,
        modelReady
            ? '本次没有可发送的图片，未调用模型；题目与已写内容仍在本机。'
                  '可以换一张可读取的图片，或补充文字后再试。'
            : '模型尚未配置，图片没有发送；题目与已写内容仍在本机。'
                  '配置模型后可以重新回答。',
      ),
      modelMissing: !modelReady,
      modelFailed: false,
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
      notice: notice,
      modelMissing: false,
      modelFailed: false,
      notSent: false,
    );
  } on LlmException catch (error, stack) {
    // 取消是用户自己停下的，不算需要排障的失败。
    if (error.failure != LlmFailure.cancelled) {
      recordFailure?.call(error, stack, kind: 'model_call');
    }
    return BuddyAnswerRun(
      config: current,
      answer: null,
      notice: _joinNotices(notice, _modelFailureNotice(error)),
      modelMissing: error.failure == LlmFailure.notConfigured,
      modelFailed: error.failure != LlmFailure.notConfigured,
      notSent: false,
      failure: error.failure,
    );
  } catch (error, stack) {
    recordFailure?.call(error, stack, kind: 'model_call');
    return BuddyAnswerRun(
      config: current,
      answer: null,
      notice: _joinNotices(notice, modelFallbackNotice),
      modelMissing: false,
      modelFailed: true,
      notSent: false,
      failure: LlmFailure.unknown,
    );
  }
}

/// 模型失败的说明按类型给出下一步；不把配置、响应体或密钥带进界面。
String _modelFailureNotice(LlmException error) {
  if (error.failure == LlmFailure.notConfigured) {
    return '模型尚未配置，这次先用本地规则回答；问题与本地回答会保存在本机。'
        '先到设置里配置模型，再回来重新回答。';
  }
  final next = switch (error.failure) {
    LlmFailure.auth => '请检查设置里的 API Key 与模型名，改好后再点「重试这次回答」。',
    LlmFailure.offline || LlmFailure.timeout => '检查网络后可以点「重试这次回答」。',
    LlmFailure.rateLimited => '请检查 API Key 的额度，稍后可以点「重试这次回答」。',
    LlmFailure.contextLimit => '可以缩短问题、减少图片或在设置中核对模型上下文上限。',
    LlmFailure.badResponse ||
    LlmFailure.toolUnsupported => '请检查设置里的接口地址与模型名，改好后再点「重试这次回答」。',
    _ => '可以点「重试这次回答」。',
  };
  return '模型调用失败（${error.shortText}），已切换为本地规则回答；'
      '问题与本地回答会保存在本机。$next';
}

String? _joinNotices(String? first, String? second) {
  if (first == null) return second;
  if (second == null) return first;
  return '$first $second';
}
