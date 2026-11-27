import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/answer_pipeline.dart';
import 'package:zhixin/application/user_failure.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/result.dart';
import 'package:zhixin/domain/rules/notices.dart';

import '../support/service_runtime.dart';

/// 固定回答的模型替身；可以选在请求期间改变数据代次。
class _FakeAi implements BuddyAi {
  _FakeAi(this.reply);

  BuddyReply reply;
  final calls = <LlmCancelToken?>[];

  @override
  Future<Result<LlmConfig?>> config() async => const Success(null);

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async {
    calls.add(cancelToken);
    return reply;
  }
}

class _Harness {
  _Harness(this.reply);

  final BuddyReply reply;
  int epoch = 0;
  late final _FakeAi ai = _FakeAi(reply);

  Future<AnswerRun> run({String Function()? localFallback}) => runAnswer(
    ai: ai,
    filesDir: () => 'unused',
    runtime: testRuntime(dataEpoch: () => epoch),
    requestEpoch: epoch,
    context: contextWithMaterialHit(),
    history: const [],
    prompt: '条件概率怎么算',
    text: '条件概率怎么算',
    imagePaths: const [],
    config: const LlmConfig(apiKey: 'test'),
    localFallback: localFallback ?? () => '本地建议',
  );
}

BuddyContext contextWithMaterialHit() => BuddyContext(
  now: DateTime(2026, 11, 6, 20, 30),
  sessionId: 'discussion-1',
  materialHits: const [
    MaterialHit(
      materialId: 'mat-1',
      materialTitle: '概率论讲义',
      pageNo: 3,
      content: '条件概率的定义',
      snippetText: '条件概率……',
    ),
  ],
);

void main() {
  test('完整回答可用，并算出本轮读到的材料页', () async {
    final h = _Harness(
      const BuddyReply(
        text: '按公式算。',
        providedSources: [
          CitationSource(materialId: 'mat-1', pageNo: 3, content: '条件概率的定义'),
          CitationSource(materialId: 'mat-2', pageNo: 7, content: '另一页'),
        ],
      ),
    );
    final result = await h.run();

    expect(result.outcome.text, '按公式算。');
    expect(result.outcome.usable, isTrue);
    expect(result.usable, isTrue);
    expect(result.answer, isNotNull);
    expect(
      result.usedPages.map((page) => page.pageKey),
      containsAll([('mat-1', 3), ('mat-2', 7)]),
    );
  });

  test('停止、中断、截断都按不可用处理，正文与原因照旧保留', () async {
    final stopped = await _Harness(
      const BuddyReply(text: '先看定义', stopped: true),
    ).run();
    expect(stopped.outcome.usable, isFalse);
    expect(stopped.outcome.stopped, isTrue);
    expect(stopped.outcome.text, '先看定义');
    expect(stopped.outcome.notices, contains(Notice.userStopped));

    final interrupted = await _Harness(
      const BuddyReply(
        text: '先看定义',
        interrupted: true,
        interruptedReason: '连接中断',
      ),
    ).run();
    expect(interrupted.outcome.usable, isFalse);
    expect(interrupted.outcome.interrupted, isTrue);
    expect(interrupted.outcome.detail, '连接中断');

    final truncated = await _Harness(
      const BuddyReply(text: '先看定义', truncated: true),
    ).run();
    expect(truncated.outcome.usable, isFalse);
    expect(truncated.outcome.truncated, isTrue);
    expect(truncated.outcome.notices, contains(Notice.answerTruncated));
  });

  test('调用失败退回本地正文，并统一按模型失败记录', () async {
    final result = await runAnswer(
      ai: _FailingAi(),
      filesDir: () => 'unused',
      runtime: testRuntime(dataEpoch: () => 0),
      requestEpoch: 0,
      context: contextWithMaterialHit(),
      history: const [],
      prompt: '问题',
      text: '问题',
      imagePaths: const [],
      config: const LlmConfig(apiKey: 'test'),
      localFallback: () => '本地建议',
    );

    expect(result.answer, isNull);
    expect(result.outcome.fromModel, isFalse);
    expect(result.outcome.modelFailed, isTrue);
    expect(result.outcome.text, '本地建议');
    expect(result.outcome.usable, isFalse);
    expect(result.usedPages, isEmpty);
  });

  test('等待模型期间数据代次变化时按可预期失败结束', () async {
    final h = _Harness(const BuddyReply(text: '迟到的回答'));
    final pending = runAnswer(
      ai: _EpochChangingAi(() => h.epoch++),
      filesDir: () => 'unused',
      runtime: testRuntime(dataEpoch: () => h.epoch),
      requestEpoch: h.epoch,
      context: contextWithMaterialHit(),
      history: const [],
      prompt: '问题',
      text: '问题',
      imagePaths: const [],
      config: const LlmConfig(apiKey: 'test'),
      localFallback: () => '本地建议',
    );

    await expectLater(
      pending,
      throwsA(
        isA<UserFailure>().having(
          (error) => error.message,
          'message',
          contains('数据已恢复或清空'),
        ),
      ),
    );
  });
}

class _FailingAi implements BuddyAi {
  @override
  Future<Result<LlmConfig?>> config() async => const Success(null);

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async => throw const LlmException(LlmFailure.offline, '连接失败');
}

class _EpochChangingAi implements BuddyAi {
  _EpochChangingAi(this.onAsk);

  final void Function() onAsk;

  @override
  Future<Result<LlmConfig?>> config() async => const Success(null);

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async {
    onAsk();
    return const BuddyReply(text: '迟到的回答');
  }
}
