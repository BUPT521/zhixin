import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/discussion_service.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/application/memory_scope_service.dart';
import 'package:zhixin/application/memory_service.dart';
import 'package:zhixin/data/attachment_store.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

/// 固定回答的模型替身；不联网，也不碰 Keystore。
class _FakeAi implements BuddyAi {
  _FakeAi({this.reply, LlmConfig? config, this.error}) : configValue = config;

  BuddyReply? reply;
  LlmConfig? configValue;
  LlmException? error;
  int calls = 0;
  int configCalls = 0;
  List<LlmImage> images = const [];
  BuddyContext? lastContext;
  List<ChatMessage> lastHistory = const [];
  String lastText = '';
  List<String> streamChunks = const [];
  Completer<void>? entered;
  Completer<void>? resume;

  @override
  Future<LlmConfig?> config() async {
    configCalls++;
    return configValue;
  }

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
    calls++;
    lastContext = context;
    lastHistory = history;
    lastText = text;
    this.images = images;
    entered?.complete();
    final waiting = resume;
    if (waiting != null) await waiting.future;
    final failure = error;
    if (failure != null) throw failure;
    final visible = StringBuffer();
    for (final chunk in streamChunks) {
      visible.write(chunk);
      onText?.call(visible.toString());
    }
    return reply ?? const BuddyReply(text: '先看定义，再回到这一步。');
  }
}

class _Harness {
  _Harness({
    BuddyReply? reply,
    LlmConfig? config,
    LlmException? error,
    this.recordFailure,
  }) : ai = _FakeAi(reply: reply, config: config, error: error) {
    clock = () => DateTime(2026, 11, 6, 20, 30);
  }

  late final DateTime Function() clock;
  final ModelFailureRecorder? recordFailure;
  int epoch = 0;
  final _FakeAi ai;
  late RawDatabase db;
  late TestRig rig;
  late ConversationRepository conversations;
  late TaskRepository tasks;
  late ScheduleRepository schedule;
  late MemoryRepository memories;
  late AttemptRepository attempts;
  late StudyRepository study;
  late MaterialRepository materials;
  late DiscussionService service;

  Future<void> open() async {
    rig = await openTestRig(clock: clock);
    db = rig.db;
    conversations = ConversationRepository(db.rawDb);
    tasks = TaskRepository(db.rawDb);
    schedule = ScheduleRepository(db.rawDb);
    memories = MemoryRepository(db.rawDb);
    attempts = AttemptRepository(db.rawDb);
    study = StudyRepository(db.rawDb);
    materials = MaterialRepository(db.rawDb);
    final policy = TimePolicy(clock: clock);
    service = DiscussionService(
      conversations: conversations,
      ai: ai,
      context: ContextService(
        tasks: tasks,
        attempts: attempts,
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: materials,
        runtime: testRuntime(policy: () => policy),
        evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: attempts,
      ),
      memories: memories,
      revisions: rig.revisions,
      tasks: tasks,
      materials: materials,
      runtime: testRuntime(
        policy: () => policy,
        filesDir: () => rig.filesDir,
        dataEpoch: () => epoch,
        recordFailure: recordFailure,
      ),
      transactions: WriteTransactions(db),
      cleanupAttachmentPaths: (paths) =>
          AttachmentStore(filesDir: rig.filesDir).cleanupCandidates(db, paths),
    );
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('恢复期间结束的模型请求不会写入新库', () async {
    final h = _Harness(reply: const BuddyReply(text: '延迟回答'));
    await h.open();
    addTearDown(h.db.close);
    final id = await h.service.createConversation();
    h.ai.entered = Completer<void>();
    h.ai.resume = Completer<void>();

    final pending = h.service.reply(conversationId: id, text: '问题');
    await h.ai.entered!.future;
    h.epoch++;
    h.ai.resume!.complete();

    await expectLater(pending, throwsA(isA<StateError>()));
    final messages = await h.conversations.recent(id);
    expect(messages, hasLength(1));
    expect(messages.single.role, 'user');
  });

  test('V1：仅凭文字开始无归属求助，结束后能从记录重新打开', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看独立性的定义'));
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '为什么这里需要独立性？');
    final id = result.userMessage.conversationId;

    expect(h.ai.calls, 1);
    expect(result.fromModel, isTrue);
    expect(result.reply, '先看独立性的定义');

    final record = await h.service.byId(id);
    expect(record, isNotNull);
    expect(record!.goalId, isNull);
    expect(record.open, isTrue);
    expect(record.title, '为什么这里需要独立性？');

    final messages = await h.service.history(id);
    expect(messages, hasLength(2));
    expect(messages.first.role, 'user');
    expect(messages.last.role, 'assistant');
    expect(messages.last.content, '先看独立性的定义');

    // 结束之后仍在记录里，按同一个标识重新打开。
    await h.service.end(id);
    final ended = await h.service.byId(id);
    expect(ended!.open, isFalse);
    final records = await h.service.records();
    expect(records.single.id, id);

    final reopened = await h.service.history(id);
    expect(reopened, hasLength(2));

    // 重新打开后继续说，还是同一条讨论。
    final again = await h.service.reply(conversationId: id, text: '那什么时候不用？');
    expect(again.userMessage.conversationId, id);
    expect((await h.service.byId(id))!.open, isTrue);
    expect(await h.service.history(id), hasLength(4));

    expect(await h.tasks.items(), isEmpty);
    expect(
      await h.schedule.blocksBetween(
        DateTime(2026, 11, 1),
        DateTime(2026, 12, 1),
      ),
      isEmpty,
    );
  });

  test('回答边生成边回调正文，用户消息先出现，最后仍保存整条回答', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义，再回到这一步。'));
    await h.open();
    addTearDown(h.db.close);
    h.ai.streamChunks = const ['先看定义，', '再回到这一步。'];

    final partials = <String>[];
    ChatMessage? shown;
    final result = await h.service.reply(
      text: '为什么这里需要独立性？',
      onUserMessage: (message) => shown = message,
      onPartial: partials.add,
    );

    expect(shown, isNotNull);
    expect(shown!.role, 'user');
    expect(shown!.content, '为什么这里需要独立性？');
    expect(partials, ['先看定义，', '先看定义，再回到这一步。']);
    expect(result.reply, '先看定义，再回到这一步。');

    final messages = await h.service.history(result.userMessage.conversationId);
    expect(messages.map((message) => message.content), [
      '为什么这里需要独立性？',
      '先看定义，再回到这一步。',
    ]);
  });

  test('停止生成时保留已经显示的部分，不写记忆和建议', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义', stopped: true));
    await h.open();
    addTearDown(h.db.close);
    h.ai.streamChunks = const ['先看定义'];

    final partials = <String>[];
    final result = await h.service.reply(
      text: '为什么这里需要独立性？',
      onPartial: partials.add,
    );

    expect(result.stopped, isTrue);
    expect(result.reply, '先看定义');
    expect(result.fromModel, isTrue);
    expect(result.notice, contains('保留已经生成的部分'));
    expect(partials, ['先看定义']);
    expect(result.nextSteps, isEmpty);
    expect(await h.tasks.items(), isEmpty);

    final messages = await h.service.history(result.userMessage.conversationId);
    expect(messages.last.content, '先看定义');
    expect(messages.last.structured?['stopped'], isTrue);
  });

  test('还没有正文就停止时记录一句已停止生成', () async {
    final h = _Harness(reply: const BuddyReply(text: '', stopped: true));
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '停一下');
    expect(result.stopped, isTrue);
    expect(result.fromModel, isFalse);
    expect(result.reply, '已停止生成。');
    expect(result.notice, '已停止生成。');

    final messages = await h.service.history(result.userMessage.conversationId);
    expect(messages.last.content, '已停止生成。');
    expect(messages.last.structured?['stopped'], isTrue);
  });

  test('流中断时保留已经显示的部分并标记中断', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先看定义',
        interrupted: true,
        interruptedReason: '网络不可用',
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    h.ai.streamChunks = const ['先看定义'];

    final partials = <String>[];
    final result = await h.service.reply(
      text: '为什么这里需要独立性？',
      onPartial: partials.add,
    );

    expect(result.interrupted, isTrue);
    expect(result.fromModel, isTrue);
    expect(result.reply, '先看定义');
    expect(result.notice, contains('生成中断'));
    expect(result.notice, contains('已保留已经生成的部分'));
    expect(result.nextSteps, isEmpty);
    expect(partials, ['先看定义']);

    final messages = await h.service.history(result.userMessage.conversationId);
    expect(messages.last.content, '先看定义');
    expect(messages.last.structured?['model'], isTrue);
    expect(messages.last.structured?['interrupted'], isTrue);
    expect(messages.last.structured?['model_failed'], isNull);

    // 中断之后仍然可以补一条完整回答，用户消息不重复。
    h.ai
      ..configValue = const LlmConfig(apiKey: 'test')
      ..reply = const BuddyReply(text: '完整回答');
    final retried = await h.service.reply(
      conversationId: result.userMessage.conversationId,
      repeatLast: true,
    );
    expect(retried.fromModel, isTrue);
    expect(retried.reply, '完整回答');
    expect(retried.userMessage.id, result.userMessage.id);
    final afterRetry = await h.service.history(
      result.userMessage.conversationId,
    );
    expect(afterRetry, hasLength(3));
    expect(afterRetry.last.content, '完整回答');
  });

  test('长讨论只读到字数预算为止，原问题仍在历史里', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义'));
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '原问题');
    final id = result.userMessage.conversationId;
    for (var index = 0; index < 80; index++) {
      await h.conversations.append(
        id,
        role: 'assistant',
        content: '第 $index 条 ${'资料' * 130}',
      );
    }

    final history = await h.service.history(id);
    expect(history.length, lessThan(83));
    expect(history.first.content, '原问题');
    expect(history.last.content, contains('第 79 条'));

    // 继续讨论时读到的历史同样停在预算内，不再把整条讨论读回。
    h.ai.reply = const BuddyReply(text: '接着讲');
    await h.service.reply(conversationId: id, text: '继续');
    expect(h.ai.lastHistory.length, lessThan(83));
    expect(h.ai.lastHistory.first.content, '原问题');
  });

  test('重答的最后一条用户消息不在预算内时仍能取到', () async {
    final h = _Harness(
      reply: const BuddyReply(text: '第一次回答'),
      config: const LlmConfig(apiKey: 'test'),
    );
    await h.open();
    addTearDown(h.db.close);

    final first = await h.service.reply(text: '第一个问题');
    final id = first.userMessage.conversationId;
    await h.conversations.append(
      id,
      role: 'assistant',
      content: '很长的一段回答：${'内容' * 6500}',
    );

    final retried = await h.service.reply(conversationId: id, repeatLast: true);

    expect(h.ai.calls, 2);
    expect(retried.userMessage.content, '第一个问题');
    expect(h.ai.lastText, '第一个问题');
    expect(h.ai.lastHistory, isEmpty);
  });

  test('模型失败降级时记录失败标记，供界面给出重试入口', () async {
    final h = _Harness(error: const LlmException(LlmFailure.offline, '断网'));
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '为什么这里需要独立性？');
    expect(result.fromModel, isFalse);
    expect(result.modelFailed, isTrue);
    expect(result.notice, contains('已切换为本地规则回答'));

    final messages = await h.service.history(result.userMessage.conversationId);
    expect(messages.last.structured?['model'], isFalse);
    expect(messages.last.structured?['model_failed'], isTrue);
  });

  test('模型失败说明随回答保存，技术细节只写进诊断', () async {
    final recorded = <(Object, String)>[];
    final h = _Harness(
      error: const LlmException(LlmFailure.auth, '401 invalid key sk-secret'),
      recordFailure: (error, stack, {required kind}) =>
          recorded.add((error, kind)),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '为什么这里需要独立性？');
    final messages = await h.service.history(result.userMessage.conversationId);

    // 重新打开讨论时，失败原因与下一步仍挂在这一次回答上。
    expect(messages.last.structured?['model_failure'], 'auth');
    final notice = messages.last.structured?['failure_notice'] as String?;
    expect(notice, contains('API Key 无效或没有权限'));
    expect(notice, contains('问题与本地回答会保存在本机'));
    expect(notice, isNot(contains('sk-secret')));
    expect(recorded, hasLength(1));
    expect(recorded.single.$2, 'model_call');
    expect((recorded.single.$1 as LlmException).detail, contains('sk-secret'));
  });

  test('V1：仅凭图片开始求助，原图按哈希与记录一起保存', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_image_');
    addTearDown(() => dir.delete(recursive: true));
    final image = File('${dir.path}/photo.jpg');
    await image.writeAsBytes([1, 2, 3, 4, 5]);

    final h = _Harness(
      reply: const BuddyReply(text: '这道题要先列出已知条件'),
      config: const LlmConfig(apiKey: 'test', allowImages: true),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(imagePaths: [image.path]);
    final id = result.userMessage.conversationId;

    expect(h.ai.calls, 1);
    expect(h.ai.images, hasLength(1));
    expect(result.userMessage.content, isEmpty);
    final hash = AssetStore.hashBytes(await image.readAsBytes());
    expect(result.userMessage.imagePaths, [hash]);

    final record = await h.service.byId(id);
    expect(record!.entryKind, 'photo');
    expect(record.displayTitle, '图片求助');

    final messages = await h.service.history(id);
    expect(messages.first.hasImages, isTrue);
  });

  test('V1：模型未开启图片输入时先存图，不调用模型', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_image2_');
    addTearDown(() => dir.delete(recursive: true));
    final image = File('${dir.path}/photo.jpg');
    await image.writeAsBytes([1, 2, 3]);

    final h = _Harness(
      config: const LlmConfig(apiKey: 'test', allowImages: false),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(imagePaths: [image.path]);
    expect(h.ai.calls, 0);
    expect(result.notice, contains('图片上传已关闭'));
    expect(result.reply, contains('图片已保存在本次讨论中'));
    expect(
      (await h.service.history(result.userMessage.conversationId))
          .first
          .imagePaths,
      [AssetStore.hashBytes(await image.readAsBytes())],
    );
  });

  test('V1：模型不可用时本地兜底，记录照常保存', () async {
    final h = _Harness(
      error: const LlmException(LlmFailure.notConfigured, '尚未配置模型'),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '独立性是什么意思');
    expect(result.fromModel, isFalse);
    // 没有配置模型不算调用失败，界面给的是配置入口而不是重试入口。
    expect(result.modelFailed, isFalse);
    expect(result.notice, contains('本地规则'));
    expect(result.reply, isNotEmpty);
    expect(
      await h.service.history(result.userMessage.conversationId),
      hasLength(2),
    );
    expect(await h.tasks.items(), isEmpty);
  });

  test('V1：配置模型之后可以重新回答同一个问题', () async {
    final h = _Harness(
      error: const LlmException(LlmFailure.notConfigured, '尚未配置模型'),
    );
    await h.open();
    addTearDown(h.db.close);

    final first = await h.service.reply(text: '为什么这里需要独立性？');
    final id = first.userMessage.conversationId;
    expect(first.fromModel, isFalse);
    // 本地回答接住这次的问题，并说明配置后可以重答。
    expect(first.reply, contains('为什么这里需要独立性'));
    expect(first.reply, contains('用模型重新回答'));

    h.ai
      ..error = null
      ..configValue = const LlmConfig(apiKey: 'test')
      ..reply = const BuddyReply(text: '独立性指两个事件同时发生的概率等于各自概率的乘积。');
    final retried = await h.service.reply(conversationId: id, repeatLast: true);

    expect(retried.fromModel, isTrue);
    expect(retried.reply, contains('独立性'));
    // 不重复写用户消息，新回答追加在后面。
    expect(retried.userMessage.id, first.userMessage.id);
    expect(h.ai.lastText, '为什么这里需要独立性？');
    final messages = await h.service.history(id);
    expect(messages, hasLength(3));
    expect(messages.where((message) => message.role == 'user'), hasLength(1));
    expect(messages.last.content, contains('独立性'));
    expect(messages.last.structured?['model'], isTrue);
  });

  test('没有配置模型时不重新回答，也不写空消息', () async {
    final h = _Harness(
      error: const LlmException(LlmFailure.notConfigured, '尚未配置模型'),
    );
    await h.open();
    addTearDown(h.db.close);

    final first = await h.service.reply(text: '为什么这里需要独立性？');
    final id = first.userMessage.conversationId;

    await expectLater(
      h.service.reply(conversationId: id, repeatLast: true),
      throwsA(isA<LlmException>()),
    );
    expect(await h.service.history(id), hasLength(2));
  });

  test('重答只读取一次模型配置', () async {
    final h = _Harness(
      error: const LlmException(LlmFailure.notConfigured, '尚未配置模型'),
    );
    await h.open();
    addTearDown(h.db.close);

    final first = await h.service.reply(text: '为什么这里需要独立性？');
    h.ai
      ..error = null
      ..configValue = const LlmConfig(apiKey: 'test');
    final before = h.ai.configCalls;
    final retried = await h.service.reply(
      conversationId: first.userMessage.conversationId,
      repeatLast: true,
    );

    // 重答先读一次配置判断能不能回答，调用模型时复用这一份，不再读第二次。
    expect(retried.fromModel, isTrue);
    expect(h.ai.configCalls - before, 1);
  });

  test('V1：达到长度上限时保留正文并提示被截断', () async {
    final h = _Harness(
      reply: const BuddyReply(text: '先看定义，再回到这一步。', truncated: true),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '独立性是什么意思');
    expect(result.fromModel, isTrue);
    expect(result.stopped, isFalse);
    expect(result.reply, '先看定义，再回到这一步。');
    expect(result.notice, contains('回答被截断'));

    final messages = await h.service.history(result.userMessage.conversationId);
    expect(messages.last.content, '先看定义，再回到这一步。');
    expect(messages.last.structured?['model'], isTrue);
  });

  test('V1：普通求助不改动既有目标和预约，未接受的建议不生成待办', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '可以先把这一问做完',
        nextSteps: [
          NextStepDraft(title: '重做第 8 题', action: '不看答案', minutes: 20),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final itemId = await h.tasks.createItem(
      title: '第三章作业',
      goalId: goalId,
      dueAt: DateTime(2026, 11, 7, 22),
    );
    final start = DateTime(2026, 11, 7, 19);
    final end = DateTime(2026, 11, 7, 19, 30);
    final blockId = await h.schedule.addBlock(
      planItemId: itemId,
      start: start,
      end: end,
      source: 'user',
    );

    final result = await h.service.reply(text: '这里为什么要用期望？');

    final goal = await h.tasks.goalById(goalId);
    expect(goal!.status, LearningGoalStatus.active);
    final items = await h.tasks.items();
    expect(items, hasLength(1));
    expect(items.single.id, itemId);
    expect(items.single.status, PlanItemStatus.todo);

    final block = await h.schedule.blockById(blockId);
    expect(block!.startAt, start);
    expect(block.endAt, end);
    expect(block.status, 'planned');
    expect(block.source, 'user');

    // 建议只存在消息里，没有被接受就不写事项。
    final messages = await h.service.history(result.userMessage.conversationId);
    final pending = DiscussionService.pendingSuggestions(messages);
    expect(pending, hasLength(1));
    expect(pending.single.draft.title, '重做第 8 题');
    expect(await h.tasks.items(), hasLength(1));
    expect(await h.service.changesFromMessages(messages), isEmpty);
  });

  test('接受建议才创建事项，撤销后建议重新出现', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先做这两步',
        nextSteps: [
          NextStepDraft(title: '重做第 8 题', minutes: 20),
          NextStepDraft(title: '整理条件概率的定义'),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final result = await h.service.reply(text: '接下来练什么');
    final id = result.userMessage.conversationId;
    final pending = DiscussionService.pendingSuggestions(
      await h.service.history(id),
    );
    expect(pending, hasLength(2));

    final accepted = await h.service.acceptNextStep(
      conversationId: id,
      messageId: pending.first.messageId,
      draft: pending.first.draft,
      goalId: null,
    );
    expect(accepted.item.goalId, isNull);
    expect(accepted.item.conversationId, id);
    expect(accepted.item.source, 'ai');
    expect(await h.tasks.items(), hasLength(1));

    final afterAccept = DiscussionService.pendingSuggestions(
      await h.service.history(id),
    );
    expect(afterAccept, hasLength(1));
    final acceptedMessage = (await h.service.history(id))
        .singleWhere((message) => message.id == pending.first.messageId);
    final recoveredChanges = await h.service.changesFromMessages([
      acceptedMessage,
    ]);
    expect(recoveredChanges, hasLength(1));
    expect(recoveredChanges.single.commitId, accepted.commitId);

    final acceptCommit = (await h.rig.engine.undoableCommits(h.db))
        .firstWhere((commit) => commit.id == accepted.commitId);
    expect(acceptCommit.action, acceptNextStepAction);

    final second = await h.service.acceptNextStep(
      conversationId: id,
      messageId: pending.last.messageId,
      draft: pending.last.draft,
      goalId: goalId,
    );
    expect(second.item.goalId, goalId);
    expect(await h.tasks.items(), hasLength(2));

    await expectLater(
      h.service.acceptNextStep(
        conversationId: id,
        messageId: pending.first.messageId,
        draft: pending.first.draft,
        goalId: null,
      ),
      throwsStateError,
    );

    // 撤销第二条，这一条建议回到消息里；第一条仍然是已接受状态。
    await h.rig.revisions.undoCommit(second.commitId);
    expect(await h.tasks.items(), hasLength(1));
    final restored = DiscussionService.pendingSuggestions(
      await h.service.history(id),
    );
    expect(restored.single.draft.title, '整理条件概率的定义');
    final refreshed = (await h.service.history(id))
        .singleWhere((message) => message.id == pending.first.messageId);
    final changes = await h.service.changesFromMessages([refreshed]);
    expect(
      changes.map((change) => change.commitId),
      isNot(contains(second.commitId)),
    );
  });

  test('暂不安排的建议在重读历史后仍保持隐藏', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '可以先订正',
        nextSteps: [NextStepDraft(title: '订正第 8 题')],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '下一步做什么');
    final conversationId = result.userMessage.conversationId;
    final suggestion = DiscussionService.pendingSuggestions(
      await h.service.history(conversationId),
    ).single;
    await h.service.dismissNextStep(
      conversationId: conversationId,
      messageId: suggestion.messageId,
      title: suggestion.draft.title,
    );

    expect(
      DiscussionService.pendingSuggestions(
        await h.service.history(conversationId),
      ),
      isEmpty,
    );
  });

  test('引用只核对本轮带入的材料，不拿库里的其他页顶替', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final currentMaterial = await h.materials.create(title: '本轮材料');
    await h.materials.addPage(
      materialId: currentMaterial,
      pageNo: 1,
      content: '条件概率的定义。',
    );
    await h.materials.addPage(
      materialId: currentMaterial,
      pageNo: 2,
      content: '留给下一次讨论的定理。',
    );
    final otherMaterial = await h.materials.create(title: '没有带入的材料');
    await h.materials.addPage(
      materialId: otherMaterial,
      pageNo: 2,
      content: '这一段也很像。',
    );
    h.ai.reply = BuddyReply(
      text: '依据见材料。',
      citations: [
        CitationDraft(
          materialId: currentMaterial,
          pageNo: 1,
          quote: '条件概率的定义。',
        ),
        CitationDraft(
          materialId: currentMaterial,
          pageNo: 2,
          quote: '留给下一次讨论的定理。',
        ),
        CitationDraft(materialId: otherMaterial, pageNo: 2, quote: '这一段也很像。'),
      ],
    );

    final result = await h.service.reply(
      text: '解释条件概率',
      materialId: currentMaterial,
      pageNo: 1,
    );
    expect(result.citations, hasLength(1));
    expect(result.citations.single.materialId, currentMaterial);
    expect(result.citations.single.verified, isTrue);
  });

  test('引用只认本轮工具真正提供的原文与当前版本', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final material = await h.materials.create(title: '补搜材料');
    await h.materials.addPage(
      materialId: material,
      pageNo: 2,
      content: '补搜到的原文：P(AB)=P(A)P(B)。',
    );
    await h.materials.addPage(
      materialId: material,
      pageNo: 3,
      content: '这一页在本轮补读之后又被更正。',
    );
    // 模拟补搜工具返回的两页：第二页与当前原文一致，第三页提供的是更正前的说法。
    h.ai.reply = BuddyReply(
      text: '依据补搜到的两页回答。',
      citations: [
        CitationDraft(materialId: material, pageNo: 2, quote: 'P(AB)=P(A)P(B)'),
        CitationDraft(
          materialId: material,
          pageNo: 3,
          quote: '这一页在本轮补读之后又被更正。',
        ),
      ],
      providedSources: [
        CitationSource(
          materialId: material,
          pageNo: 2,
          content: '补搜到的原文：P(AB)=P(A)P(B)。',
          sourceVersion: 'v2',
        ),
        CitationSource(
          materialId: material,
          pageNo: 3,
          content: '更正前的旧说法。',
          sourceVersion: 'v3-old',
        ),
      ],
    );

    final result = await h.service.reply(text: '独立性怎么判断');
    expect(result.citations, hasLength(1));
    expect(result.citations.single.pageNo, 2);
    expect(result.citations.single.verified, isTrue);
  });

  test('两条同名建议可以分别接受，不会一接受就都消失', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '接下来可以这样练。',
        nextSteps: [
          NextStepDraft(title: '做一组练习', minutes: 20),
          NextStepDraft(title: '做一组练习', minutes: 30),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '下一步做什么');
    final pending = DiscussionService.pendingSuggestions([
      result.assistantMessage,
    ]);
    expect(pending, hasLength(2));
    expect(pending.map((item) => item.stepId), ['s1', 's2']);

    final accepted = await h.service.acceptNextStep(
      conversationId: result.assistantMessage.conversationId,
      messageId: result.assistantMessage.id,
      draft: pending.first.draft,
      stepId: pending.first.stepId,
    );
    expect(accepted.item.title, '做一组练习');

    final message = await h.conversations.messageById(
      result.assistantMessage.id,
    );
    final left = DiscussionService.pendingSuggestions([message!]);
    expect(left, hasLength(1));
    expect(left.single.stepId, 's2');

    final undone = await h.rig.revisions.undoCommit(accepted.commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    final restored = await h.conversations.messageById(
      result.assistantMessage.id,
    );
    expect(DiscussionService.pendingSuggestions([restored!]), hasLength(2));
  });

  test('文字追问仍带上一条消息的原图，而不是只发占位符', () async {
    final h = _Harness(
      config: const LlmConfig(
        baseUrl: 'https://example.com/v1',
        model: 'test-model',
        apiKey: 'test-key',
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    final image = File('${h.rig.filesDir}/question_images/m-1.jpg');
    await image.parent.create(recursive: true);
    await image.writeAsBytes([1, 2, 3]);

    final first = await h.service.reply(text: '这题怎么做', imagePaths: ['m-1.jpg']);
    expect(h.ai.images, hasLength(1));

    await h.service.reply(
      conversationId: first.assistantMessage.conversationId,
      text: '我还卡在这一步',
    );
    expect(h.ai.lastText, '我还卡在这一步');
    expect(h.ai.images, hasLength(1));
  });

  test('模型推断的记忆先出卡片，用户记下后才写入', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先看定义',
        memories: [
          MemoryDraft(
            kind: MemoryKind.difficulty,
            content: '放缩方向不确定',
            source: MemorySource.inferred,
          ),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '继续讲放缩');
    final conversationId = result.userMessage.conversationId;
    expect(
      await h.memories.activeForContext(now: DateTime(2026, 11, 6, 20, 30)),
      isEmpty,
    );
    var items = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(items, hasLength(1));
    expect(items.single.pending, isTrue);
    expect(items.single.draft.source, MemorySource.inferred);

    final accepted = await h.service.acceptMemoryItem(
      conversationId: conversationId,
      messageId: items.single.ownerId,
      itemId: items.single.itemId,
    );
    expect(accepted.applied, isTrue);
    final memories = await h.memories.activeForContext(
      now: DateTime(2026, 11, 6, 20, 30),
    );
    expect(memories.single.content, '放缩方向不确定');
    expect(memories.single.sourceKind, 'message');

    items = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(items.single.applied, isTrue);
    expect(items.single.commitId, accepted.change!.commitId);

    await h.rig.revisions.undoCommit(accepted.change!.commitId);
    expect(
      await h.memories.activeForContext(now: DateTime(2026, 11, 6, 20, 30)),
      isEmpty,
    );
    // 撤销写入后卡片回到待确认，用户可以重新决定。
    final restored = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(restored.single.pending, isTrue);
    expect(restored.single.commitId, isNull);
  });

  test('用户明确说的记忆先写入，卡片可以撤销', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '记住了',
        memories: [
          MemoryDraft(
            kind: MemoryKind.preference,
            content: '喜欢先看例子',
            source: MemorySource.user,
          ),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '我喜欢先看例子');
    final conversationId = result.userMessage.conversationId;
    final memories = await h.memories.activeForContext(
      now: DateTime(2026, 11, 6, 20, 30),
    );
    expect(memories.single.content, '喜欢先看例子');
    expect(memories.single.sourceKind, 'user');

    final items = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(items.single.applied, isTrue);
    expect(items.single.commitId, isNotNull);

    await h.rig.revisions.undoCommit(items.single.commitId!);
    expect(
      await h.memories.activeForContext(now: DateTime(2026, 11, 6, 20, 30)),
      isEmpty,
    );
    expect(
      (await h.service.memoryItemsFromMessages(
        await h.service.history(conversationId),
      )).single.pending,
      isTrue,
    );
  });

  test('用户明确说出的多条记忆一次写入，按同一条提交撤销', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '记住了',
        memories: [
          MemoryDraft(
            kind: MemoryKind.preference,
            content: '喜欢先看例子',
            source: MemorySource.user,
          ),
          MemoryDraft(
            kind: MemoryKind.progress,
            content: '能独立列出条件',
            source: MemorySource.user,
          ),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '我喜欢先看例子，也能独立列出条件');
    final conversationId = result.userMessage.conversationId;
    final items = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(items, hasLength(2));
    expect(items.map((item) => item.draft.content).toSet(), {
      '喜欢先看例子',
      '能独立列出条件',
    });

    // 同一批写入落在同一条提交里，两张卡片指向同一次写入。
    expect({for (final item in items) item.commitId}, hasLength(1));
    final commitId = items.first.commitId!;
    final commit = (await h.rig.engine.undoableCommits(h.db))
        .firstWhere((item) => item.id == commitId);
    expect(commit.action, writeMemoryAction);

    await h.rig.revisions.undoCommit(commitId);
    final remaining = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(remaining, hasLength(2));
    expect(remaining.every((item) => item.pending), isTrue);
  });

  test('记忆写入失败时回答照常保存，卡片留作待确认', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '记住了',
        memories: [
          MemoryDraft(
            kind: MemoryKind.preference,
            content: '喜欢先看例子',
            source: MemorySource.user,
          ),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    await h.db.execute('''
      CREATE TRIGGER fail_memory_insert BEFORE INSERT ON memory
      BEGIN
        SELECT RAISE(ABORT, '记忆写入失败');
      END;
    ''');

    final result = await h.service.reply(text: '我喜欢先看例子');
    final conversationId = result.userMessage.conversationId;
    expect(result.notice, contains('记忆保存失败'));
    expect(result.assistantMessage.content, '记住了');
    final messages = await h.service.history(conversationId);
    expect(messages, hasLength(2));
    expect(messages.last.content, '记住了');
    expect(
      await h.memories.activeForContext(now: DateTime(2026, 11, 6, 20, 30)),
      isEmpty,
    );
    var items = await h.service.memoryItemsFromMessages(messages);
    expect(items.single.pending, isTrue);
    expect(items.single.draft.source, MemorySource.user);

    // 去掉故障后，用户可以在卡片上重试。
    await h.db.execute('DROP TRIGGER fail_memory_insert');
    final accepted = await h.service.acceptMemoryItem(
      conversationId: conversationId,
      messageId: items.single.ownerId,
      itemId: items.single.itemId,
    );
    expect(accepted.applied, isTrue);
    final retried = await h.memories.activeForContext(
      now: DateTime(2026, 11, 6, 20, 30),
    );
    expect(retried.single.sourceKind, 'user');
    items = await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    );
    expect(items.single.applied, isTrue);
  });

  test('推断的记忆已经存在时给出提示并收起卡片', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '这条已经记过',
        memories: [
          MemoryDraft(
            kind: MemoryKind.constraint,
            content: '本周晚上只有半小时',
            source: MemorySource.inferred,
          ),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    await h.memories.create(kind: MemoryKind.constraint, content: '本周晚上只有半小时');

    final result = await h.service.reply(text: '这周晚上只有半小时');
    final conversationId = result.userMessage.conversationId;
    final item = (await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    )).single;

    final accepted = await h.service.acceptMemoryItem(
      conversationId: conversationId,
      messageId: item.ownerId,
      itemId: item.itemId,
    );
    expect(accepted.applied, isFalse);
    expect(accepted.notice, contains('已经存在'));
    expect(
      await h.service.memoryItemsFromMessages(
        await h.service.history(conversationId),
      ),
      isEmpty,
    );
    expect(
      await h.service.changesFromMessages(
        await h.service.history(conversationId),
      ),
      isEmpty,
    );
  });

  test('用户点不记后卡片收起，记忆没有写入', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '可以不记',
        memories: [
          MemoryDraft(
            kind: MemoryKind.progress,
            content: '能独立列出条件',
            source: MemorySource.inferred,
          ),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final result = await h.service.reply(text: '我好像会了');
    final conversationId = result.userMessage.conversationId;
    final item = (await h.service.memoryItemsFromMessages(
      await h.service.history(conversationId),
    )).single;
    await h.service.dismissMemoryItem(
      conversationId: conversationId,
      messageId: item.ownerId,
      itemId: item.itemId,
    );

    expect(
      await h.memories.activeForContext(now: DateTime(2026, 11, 6, 20, 30)),
      isEmpty,
    );
    expect(
      await h.service.memoryItemsFromMessages(
        await h.service.history(conversationId),
      ),
      isEmpty,
    );
  });

  test('V2：创建目标不归档其他目标，暂停只改状态', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final first = await h.tasks.createGoal(title: '概率论期末');
    final second = await h.tasks.createGoal(title: '线性代数作业');
    final goals = await h.tasks.goals();
    expect(goals, hasLength(2));
    expect(
      goals.every((goal) => goal.status == LearningGoalStatus.active),
      isTrue,
    );

    final itemId = await h.tasks.createItem(title: '第三章作业', goalId: first);
    final start = DateTime(2026, 11, 7, 19);
    final blockId = await h.schedule.addBlock(
      planItemId: itemId,
      start: start,
      end: start.add(const Duration(minutes: 30)),
    );
    final doneId = await h.tasks.createItem(title: '第二节作业', goalId: second);
    await StudyPlanRepository(h.db.rawDb)
        .setItemStatus(doneId, PlanItemStatus.done);

    await h.tasks.pauseGoal(first);
    expect((await h.tasks.goalById(first))!.status, LearningGoalStatus.paused);
    expect((await h.tasks.goalById(second))!.status, LearningGoalStatus.active);

    // 相关未来安排与已完成记录保持原样。
    final block = await h.schedule.blockById(blockId);
    expect(block!.startAt, start);
    expect(block.status, 'planned');
    final items = await h.tasks.items();
    expect(
      items.firstWhere((item) => item.id == doneId).status,
      PlanItemStatus.done,
    );
    expect(items.any((item) => item.id == itemId), isTrue);

    // 暂停的目标不参与“现在”的推荐。
    expect(await h.tasks.items(openOnly: true, onlyActiveGoals: true), isEmpty);
  });

  test('V2：归属只来自用户明确选择，未选择的事项独立存在', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '可以这样继续',
        nextSteps: [NextStepDraft(title: '整理一页笔记')],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final goalA = await h.tasks.createGoal(title: '概率论期末');
    final goalB = await h.tasks.createGoal(title: '线性代数作业');

    final withGoal = await h.service.reply(text: '这题写在概率论里');
    final withGoalId = withGoal.userMessage.conversationId;
    await h.service.setGoal(withGoalId, goalA);
    expect((await h.service.byId(withGoalId))!.goalId, goalA);

    final pendingA = DiscussionService.pendingSuggestions(
      await h.service.history(withGoalId),
    );
    final acceptedA = await h.service.acceptNextStep(
      conversationId: withGoalId,
      messageId: pendingA.single.messageId,
      draft: pendingA.single.draft,
      goalId: goalA,
    );
    expect(acceptedA.item.goalId, goalA);

    final noGoal = await h.service.reply(text: '随手问一个线性代数的问题');
    final noGoalId = noGoal.userMessage.conversationId;
    expect((await h.service.byId(noGoalId))!.goalId, isNull);
    final pendingB = DiscussionService.pendingSuggestions(
      await h.service.history(noGoalId),
    );
    final acceptedB = await h.service.acceptNextStep(
      conversationId: noGoalId,
      messageId: pendingB.single.messageId,
      draft: pendingB.single.draft,
      goalId: null,
    );
    expect(acceptedB.item.goalId, isNull);

    final items = await h.tasks.items();
    expect(items, hasLength(2));
    expect(items.where((item) => item.goalId == goalA), hasLength(1));
    expect(items.where((item) => item.goalId == goalB), isEmpty);
    expect(items.where((item) => item.goalId == null), hasLength(1));
  });

  test('V3：按页码带入材料，引用逐字核对后才算已核实', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final materialId = await h.materials.create(
      title: '概率论课件',
      kind: 'slides',
      sourceRef: '第 12 讲',
      goalId: goalId,
    );
    await h.materials.addPage(
      materialId: materialId,
      pageNo: 12,
      label: '条件概率',
      content: '条件概率的定义是 P(A|B)=P(AB)/P(B)。',
    );
    h.ai.reply = BuddyReply(
      text: '先看这一页的定义',
      citations: [
        CitationDraft(
          materialId: materialId,
          pageNo: 12,
          quote: 'P(A|B)=P(AB)/P(B)',
        ),
        CitationDraft(
          materialId: materialId,
          pageNo: 12,
          quote: '独立性要求 P(AB)=P(A)P(B)',
        ),
      ],
    );

    final result = await h.service.reply(
      text: '条件概率怎么算',
      materialId: materialId,
      pageNo: 12,
    );
    expect(h.ai.lastContext!.materialPage!.content, contains('P(A|B)'));
    expect(h.ai.lastContext!.materialPage!.pageNo, 12);
    expect(result.citations, hasLength(2));
    expect(result.citations.first.verified, isTrue);
    expect(result.citations.last.verified, isFalse);

    final record = await h.service.byId(result.userMessage.conversationId);
    expect(record!.materialId, materialId);
    expect(record.pageNo, 12);
    expect(record.materialTitle, '概率论课件');

    final messages = await h.service.history(record.id);
    final citations = DiscussionService.citationsOf(messages.last);
    expect(citations, hasLength(2));
    expect(citations.first.verified, isTrue);
    expect(citations.last.verified, isFalse);

    final prompt = buildBuddySystemPrompt(h.ai.lastContext!);
    expect(prompt, contains('材料原文'));
    expect(prompt, contains('本次材料：material_id='));
    expect(prompt, contains('《概率论课件》第 12 页'));
    expect(prompt, contains('quote 必须逐字摘录'));
  });

  test('V3：能检索较早的相关记录，其他目标的内容不参加判断', () async {
    final h = _Harness(reply: const BuddyReply(text: '接着上次说'));
    await h.open();
    addTearDown(h.db.close);

    final goalA = await h.tasks.createGoal(title: '概率论期末');
    final goalB = await h.tasks.createGoal(title: '线性代数作业');
    final oldA = await h.service.reply(text: '条件概率和独立性有什么区别');
    await h.service.setGoal(oldA.userMessage.conversationId, goalA);
    final oldB = await h.service.reply(text: '矩阵的秩怎么求');
    await h.service.setGoal(oldB.userMessage.conversationId, goalB);

    final materialA = await h.materials.create(title: '概率论讲义', goalId: goalA);
    await h.materials.addPage(
      materialId: materialA,
      pageNo: 3,
      content: '独立性要求条件概率等于无条件概率。',
    );
    final materialB = await h.materials.create(title: '线性代数讲义', goalId: goalB);
    await h.materials.addPage(
      materialId: materialB,
      pageNo: 3,
      content: '矩阵的秩是线性无关行向量的最大个数。',
    );

    final result = await h.service.reply(
      text: '条件概率和独立性',
      goalId: goalA,
      materialId: materialA,
      pageNo: 3,
    );
    final context = h.ai.lastContext!;
    expect(
      context.relatedRecords.map((record) => record.conversationId),
      contains(oldA.userMessage.conversationId),
    );
    expect(
      context.relatedRecords.map((record) => record.conversationId),
      isNot(contains(oldB.userMessage.conversationId)),
    );
    expect(
      context.materialHits.map((hit) => hit.materialTitle),
      isNot(contains('线性代数讲义')),
    );
    expect(
      context.relatedRecords.every((record) => record.content.contains('条件概率')),
      isTrue,
    );

    // 检索通过本地查询完成，不依赖模型。
    final hits = await h.materials.search('独立性', goalId: goalA);
    expect(hits.single.materialTitle, '概率论讲义');
    expect(result.userMessage.conversationId, isNotNull);
  });

  test('V3：更正只留追溯，回答以当前有效的记忆与材料原文为准', () async {
    final h = _Harness(reply: const BuddyReply(text: '按你的纠正来'));
    await h.open();
    addTearDown(h.db.close);

    final materialId = await h.materials.create(title: '概率论课件');
    await h.materials.addPage(
      materialId: materialId,
      pageNo: 12,
      content: '条件概率的定义是 P(A|B)=P(AB)/P(B)。',
    );
    final memoryId = await h.memories.create(
      kind: MemoryKind.difficulty,
      content: '以为条件概率和独立性等价',
      sourceKind: 'user',
    );
    await h.memories.supersede(memoryId);

    await h.service.reply(text: '再看条件概率', materialId: materialId, pageNo: 12);
    final context = h.ai.lastContext!;
    expect(
      context.memories.any((memory) => memory.content.contains('等价')),
      isFalse,
    );
    final prompt = buildBuddySystemPrompt(context);
    expect(prompt, isNot(contains('用户纠正过的内容')));
    expect(prompt, contains('P(A|B)=P(AB)/P(B)'));

    // 更正页内原文后，页面内容与后续上下文都是新原文；旧摘录不再能通过核对。
    final page = await h.materials.page(materialId, 12);
    await h.materials.correctPage(
      pageId: page!.id,
      content: '条件概率的定义是 P(A∩B)/P(B)。',
      label: page.label,
    );
    h.ai.reply = BuddyReply(
      text: '再看一次',
      citations: [
        CitationDraft(
          materialId: materialId,
          pageNo: 12,
          quote: 'P(A|B)=P(AB)/P(B)',
        ),
      ],
    );
    final again = await h.service.reply(
      text: '再核对一次',
      materialId: materialId,
      pageNo: 12,
    );
    expect(again.citations.single.verified, isFalse);
    expect(
      buildBuddySystemPrompt(h.ai.lastContext!),
      contains('条件概率的定义是 P(A∩B)/P(B)'),
    );
  });

  test('修改后删除或过期的记忆不进入回答', () async {
    final h = _Harness(reply: const BuddyReply(text: '好的'));
    await h.open();
    addTearDown(h.db.close);
    final memoryService = MemoryService(
      h.memories,
      transactions: WriteTransactions(h.db),
    );

    final removed = await h.memories.create(
      kind: MemoryKind.difficulty,
      content: '以为条件概率和独立性等价',
    );
    await memoryService.save(
      (await h.memories.byId(removed))!,
      content: '条件概率不等于独立性',
    );
    await memoryService.delete(removed);

    final expired = await h.memories.create(
      kind: MemoryKind.constraint,
      content: '本周晚上只有半小时',
    );
    await memoryService.save(
      (await h.memories.byId(expired))!,
      content: '本周晚上只有一小时',
      validUntil: DateTime(2026, 11, 5),
    );

    await h.service.reply(text: '继续讲条件概率');
    final context = h.ai.lastContext!;
    expect(context.memories, isEmpty);
    final prompt = buildBuddySystemPrompt(context);
    expect(prompt, isNot(contains('条件概率不等于独立性')));
    expect(prompt, isNot(contains('本周晚上只有一小时')));
  });

  test('清空学习记录会删掉消息与作答，记忆保留', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final conversation = await h.conversations.create(title: '清空测试');
    await h.conversations.append(conversation, role: 'user', content: '第一句');
    await h.conversations.append(
      conversation,
      role: 'assistant',
      content: '第二句',
    );
    final session = await h.study.start();
    await h.attempts.ensureOpenAttempt(conversation, sessionId: session.id);
    final memoryId = await h.memories.create(
      kind: MemoryKind.difficulty,
      content: '一条与讨论无关的记忆',
    );

    await h.service.clear(conversation);

    expect(await h.conversations.byId(conversation), isNull);
    expect(await h.db.query('message'), isEmpty);
    expect(await h.db.query('attempt'), isEmpty);
    // 场次没有指向记录的列，清空后没有其他作答引用时一起删除。
    expect(await h.db.query('study_session'), isEmpty);
    expect((await h.db.query('memory')).single['id'], memoryId);
  });
}
