import 'dart:io';
import 'dart:typed_data';

import '../ai/ai_chat_service.dart';
import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../data/db/write_transactions.dart';
import '../data/revisions/asset_store.dart';
import '../data/revisions/revision_actions.dart';
import '../data/revisions/revision_engine.dart';
import '../data/revisions/revision_service.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/evidence.dart';
import '../domain/models/material.dart';
import '../domain/models/memory.dart';
import '../domain/models/study.dart';
import '../domain/rules/content_identity.dart';
import 'buddy_fallback.dart';
import '../domain/rules/time_policy.dart';
import '../domain/rules/time_format.dart';
import 'buddy_actions.dart';
import 'buddy_answer.dart';
import 'context_service.dart';
import 'memory_scope_service.dart';
import 'memory_view.dart';
import 'reply_outcome.dart';

/// 一次求助的结果：两条消息、引用与要展示的下一步建议。
///
/// 记忆写入后的卡片状态与可撤销回执都从消息里读，不在结果里另带一份。
class ChatResult {
  const ChatResult({
    required this.userMessage,
    required this.assistantMessage,
    required this.reply,
    this.skipped = const [],
    this.nextSteps = const [],
    this.citations = const [],
    this.fromModel = false,
    this.stopped = false,
    this.interrupted = false,
    this.modelFailed = false,
    this.notice,
  });

  final ChatMessage userMessage;
  final ChatMessage assistantMessage;
  final String reply;
  final List<String> skipped;
  final List<NextStepDraft> nextSteps;

  /// 本次回答引用的材料页；逐字核对不上的条目为未核实。
  final List<Citation> citations;
  final bool fromModel;

  /// 用户在生成中停止；回答只保留已经显示的部分。
  final bool stopped;

  /// 生成中断；回答只保留中断前已经显示的部分。
  final bool interrupted;

  /// 模型调用失败后换成本地规则回答；界面据此给出重试入口。
  final bool modelFailed;
  final String? notice;
}

/// 一条还没有被接受的下一步建议，带上它所在的消息与消息内的编号。
class PendingSuggestion {
  const PendingSuggestion({
    required this.messageId,
    required this.stepId,
    required this.draft,
  });

  final int messageId;

  /// 建议在这条消息里的稳定编号；同名建议靠它分别接受或忽略。
  final String stepId;
  final NextStepDraft draft;
}

/// 用户接受一条建议后的结果。
class AcceptedSuggestion {
  const AcceptedSuggestion({required this.item, required this.commitId});

  final PlanItem item;
  final int commitId;
}

/// 从文字或图片开始的一次讨论。
///
/// 讨论不要求先有目标，普通求助只写消息与记忆：不写 `plan_item`，不改动既有
/// `schedule_block`。带入材料时按页码读取原文，回答里的引用先由程序核对再显示；
/// 材料的原文只在材料页更正，回答读到的始终是当前保存的原文。
class DiscussionService {
  DiscussionService({
    required this.conversations,
    required this.ai,
    required this.context,
    required this.memoryScope,
    required this.memories,
    required this.revisions,
    required this.tasks,
    required this.materials,
    required this.policy,
    required this.transactions,
    required this.filesDir,
    required this.cleanupAttachmentPaths,
    AssetStore? assets,
    AttachmentCache? cache,
    int Function()? dataEpoch,
    this.recordFailure,
  }) : assets = assets ?? AssetStore(),
       cache = cache ?? AttachmentCache(filesDir: filesDir),
       dataEpoch = dataEpoch ?? _zeroDataEpoch;

  final ConversationRepository conversations;
  final BuddyAi ai;
  final ContextService context;

  /// 讨论与作答共用的记忆范围判断。
  final MemoryScopeService memoryScope;
  final MemoryRepository memories;

  /// 回执指向提交历史，撤销与“是否仍可撤销”都读这里。
  final RevisionService revisions;
  final TaskRepository tasks;
  final MaterialRepository materials;
  final TimePolicy Function() policy;

  /// 图片字节按哈希写入同一个库；业务行只保存哈希引用。
  final AssetStore assets;
  final AttachmentCache cache;

  /// 写入记录与撤销都经这份连接；与仓库共用同一个库。
  final WriteTransactions transactions;

  /// 图片按文件名保存，读取时拼回应用私有目录。
  final String Function() filesDir;
  final Future<void> Function(Iterable<String> paths) cleanupAttachmentPaths;
  final int Function() dataEpoch;

  /// 模型调用的类型、消息与调用栈只交给本机诊断记录，不进入界面说明。
  final ModelFailureRecorder? recordFailure;

  /// 记录列表；[answerStatus] 按作答判定筛选，[limit] 与 [offset] 用于按页读取。
  Future<List<ConversationRecord>> records({
    int? goalId,
    bool unassignedOnly = false,
    String? answerStatus,
    int? limit = 200,
    int offset = 0,
  }) => conversations.list(
    goalId: goalId,
    unassignedOnly: unassignedOnly,
    answerStatus: answerStatus,
    limit: limit,
    offset: offset,
  );

  Future<ConversationRecord?> byId(int id) => conversations.byId(id);

  /// 发给模型的近期讨论：从最新一条向前累计到字数预算为止。
  ///
  /// 讨论发送、重答与系统学习焦点都只要最近这一段；原先先把整条讨论读回、
  /// 再由提示词按 12000 字裁剪，讨论越长读取越大。第一条用户消息另行补在
  /// 最前，与提示词的选取规则一致。
  Future<List<ChatMessage>> history(int id) => _promptHistory(id);

  Future<List<ChatMessage>> _promptHistory(
    int conversationId, {
    int? beforeMessageId,
  }) async {
    final recent = <ChatMessage>[];
    var used = 0;
    int? before = beforeMessageId;
    while (used < buddyHistoryCharBudget) {
      final page = await conversations.historyPage(
        conversationId,
        beforeMessageId: before,
        limit: 50,
      );
      if (page.messages.isEmpty) break;
      recent.insertAll(0, page.messages);
      for (final message in page.messages) {
        used += message.content.trim().isEmpty ? 7 : message.content.length + 1;
      }
      if (!page.hasOlder) break;
      before = page.messages.first.id;
    }
    final first = await conversations.firstUserMessage(
      conversationId,
      beforeMessageId: beforeMessageId,
    );
    if (first == null || recent.any((message) => message.id == first.id)) {
      return recent;
    }
    return [first, ...recent];
  }

  Future<({List<ChatMessage> messages, bool hasOlder})> historyPage(
    int id, {
    int? beforeMessageId,
    int limit = 50,
  }) => conversations.historyPage(
    id,
    beforeMessageId: beforeMessageId,
    limit: limit,
  );

  Future<List<LearningGoal>> activeGoals() => tasks.activeGoals();

  Future<List<LearningGoal>> goals() => tasks.goals();

  /// 新建一条还没有消息的讨论，用于从材料页开始或从记录里手动开一条。
  Future<int> createConversation({
    String? title,
    int? goalId,
    int? materialId,
    int? pageNo,
  }) {
    return conversations.create(
      title: title,
      goalId: goalId,
      materialId: materialId,
      pageNo: pageNo,
    );
  }

  /// 一条讨论里的一次回答请求：新讨论、继续讨论与重答最后一条走同一个入口。
  ///
  /// [conversationId] 为空表示新建一条讨论，此时文字与图片至少要有一个；
  /// [materialId]、[pageNo] 与 [goalId] 只在新建时使用，继续讨论时归属与材料
  /// 从记录本身读取。已经结束的讨论会重新打开。
  ///
  /// [repeatLast] 为真时用当前配置的模型重答最后一条用户消息：不重复写用户
  /// 消息，也不改写原来的回答，新回答追加在后面，问题、作答与材料位置都保留，
  /// 用户可以对照两条回答。
  ///
  /// [onUserMessage] 在用户消息写入之后立即回调，让界面先显示这条消息；
  /// [onPartial] 在模型边生成时回调正文，最终仍以返回的 [ChatResult] 为准。
  Future<ChatResult> reply({
    int? conversationId,
    String text = '',
    List<String> imagePaths = const [],
    bool repeatLast = false,
    int? materialId,
    int? pageNo,
    int? goalId,
    Set<String> broughtIdentities = const {},
    void Function(ChatMessage message)? onUserMessage,
    void Function(String text)? onPartial,
    LlmCancelToken? cancelToken,
  }) {
    if (conversationId == null) {
      if (repeatLast) throw ArgumentError('新讨论没有可以重新回答的问题');
      return _openConversation(
        text: text,
        imagePaths: imagePaths,
        materialId: materialId,
        pageNo: pageNo,
        goalId: goalId,
        broughtIdentities: broughtIdentities,
        onUserMessage: onUserMessage,
        onPartial: onPartial,
        cancelToken: cancelToken,
      );
    }
    if (repeatLast) {
      return _repeatLast(
        conversationId: conversationId,
        onPartial: onPartial,
        cancelToken: cancelToken,
      );
    }
    return _continueConversation(
      conversationId: conversationId,
      text: text,
      imagePaths: imagePaths,
      broughtIdentities: broughtIdentities,
      onUserMessage: onUserMessage,
      onPartial: onPartial,
      cancelToken: cancelToken,
    );
  }

  /// 新建一条讨论并立即写入第一条消息。
  Future<ChatResult> _openConversation({
    required String text,
    required List<String> imagePaths,
    required int? materialId,
    required int? pageNo,
    required int? goalId,
    required Set<String> broughtIdentities,
    required void Function(ChatMessage message)? onUserMessage,
    required void Function(String text)? onPartial,
    required LlmCancelToken? cancelToken,
  }) async {
    final trimmed = text.trim();
    final paths = _cleanPaths(imagePaths);
    if (trimmed.isEmpty && paths.isEmpty) {
      throw ArgumentError('请输入问题或添加图片');
    }
    final entryKind = trimmed.isEmpty
        ? 'photo'
        : (paths.isEmpty ? 'text' : 'text_photo');
    final id = await conversations.create(
      title: _titleFor(trimmed),
      entryKind: entryKind,
      goalId: goalId,
      materialId: materialId,
      pageNo: pageNo,
    );
    return _continueConversation(
      conversationId: id,
      text: trimmed,
      imagePaths: paths,
      broughtIdentities: broughtIdentities,
      onUserMessage: onUserMessage,
      onPartial: onPartial,
      cancelToken: cancelToken,
    );
  }

  /// 在同一条讨论里继续说；已经结束的讨论会重新打开。
  Future<ChatResult> _continueConversation({
    required int conversationId,
    required String text,
    required List<String> imagePaths,
    required Set<String> broughtIdentities,
    required void Function(ChatMessage message)? onUserMessage,
    required void Function(String text)? onPartial,
    required LlmCancelToken? cancelToken,
  }) async {
    final requestEpoch = dataEpoch();
    final trimmed = text.trim();
    final paths = _cleanPaths(imagePaths);
    if (trimmed.isEmpty && paths.isEmpty) {
      throw ArgumentError('请输入消息内容或添加图片');
    }
    final record = await conversations.byId(conversationId);
    if (record == null) throw StateError('未找到这条讨论');
    final needsReopen = !record.open;

    final before = await _promptHistory(conversationId);
    final ingested = await _ingest(paths);
    final userMessage = await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      if (needsReopen) {
        await conversations.reopen(conversationId, transaction: txn);
      }
      for (final item in ingested.pending) {
        await assets.putBytes(txn.executor, item.hash, item.bytes);
      }
      return conversations.append(
        conversationId,
        role: 'user',
        content: trimmed,
        imagePaths: ingested.refs,
        transaction: txn,
      );
    }, label: '提交讨论消息');
    onUserMessage?.call(userMessage);
    return _answer(
      conversationId: conversationId,
      record: record,
      text: trimmed,
      imageRefs: ingested.refs,
      hasImages: paths.isNotEmpty,
      history: before,
      requestEpoch: requestEpoch,
      userMessage: userMessage,
      broughtIdentities: broughtIdentities,
      onPartial: onPartial,
      cancelToken: cancelToken,
    );
  }

  /// 用当前配置的模型重新回答最后一条用户消息。
  ///
  /// 本地兜底回答已经保存，配置好模型之后从同一条讨论接着回答同一个问题：
  /// 不重复写用户消息，也不改写原来的回答，新回答追加在后面。问题、作答与
  /// 材料位置都保留，用户可以对照两条回答。
  Future<ChatResult> _repeatLast({
    required int conversationId,
    required void Function(String text)? onPartial,
    required LlmCancelToken? cancelToken,
  }) async {
    final requestEpoch = dataEpoch();
    final record = await conversations.byId(conversationId);
    if (record == null) throw StateError('未找到这条讨论');
    if (!record.open) await conversations.reopen(conversationId);
    final config = await _configOrNull();
    if (config == null || !config.isConfigured) {
      throw const LlmException(LlmFailure.notConfigured, '模型尚未配置');
    }
    final userMessage = await conversations.lastUserMessage(conversationId);
    if (userMessage == null) {
      throw StateError('这条讨论还没有可以重新回答的问题');
    }
    return _answer(
      conversationId: conversationId,
      record: record,
      text: userMessage.content,
      imageRefs: userMessage.imagePaths,
      hasImages: userMessage.hasImages,
      history: await _promptHistory(
        conversationId,
        beforeMessageId: userMessage.id,
      ),
      requestEpoch: requestEpoch,
      userMessage: userMessage,
      config: config,
      onPartial: onPartial,
      cancelToken: cancelToken,
    );
  }

  /// 调用模型并写回回答；模型不可用时按同一入口写本地兜底。
  ///
  /// [record] 是调用方已经读到的记录，材料位置与记忆范围都从它取，不再按
  /// 编号读一次；[config] 同理，重答已经读过配置，传进来复用。
  Future<ChatResult> _answer({
    required int conversationId,
    required ConversationRecord record,
    required String text,
    required List<String> imageRefs,
    required bool hasImages,
    required List<ChatMessage> history,
    required int requestEpoch,
    required ChatMessage userMessage,
    Set<String> broughtIdentities = const {},
    LlmConfig? config,
    void Function(String text)? onPartial,
    LlmCancelToken? cancelToken,
  }) async {
    // 归属与记忆范围从同一条规则来：记录上没有目标时，沿用最近一次学习的
    // 目标，与作答求助一致。
    final resolved = await memoryScope.resolve(conversationId, record: record);
    final facts = await context.load(
      mode: BuddyMode.chat,
      goalId: resolved.goalId,
      materialId: record.materialId,
      pageNo: record.pageNo,
      conversationId: conversationId,
      query: text,
      broughtIdentities: broughtIdentities,
    );
    // 用户只追问文字时，把这条讨论里最近一次带图消息的原图一起发给模型；
    // 历史消息本身没有图片字段，只放占位符会让模型看不到题目原图。
    final earlierImages = imageRefs.isNotEmpty
        ? const <String>[]
        : (history.reversed
                  .where(
                    (message) => message.role == 'user' && message.hasImages,
                  )
                  .firstOrNull
                  ?.imagePaths ??
              const <String>[]);
    final sentImages = imageRefs.isNotEmpty ? imageRefs : earlierImages;
    final run = await askBuddyModel(
      ai: ai,
      filesDir: filesDir,
      context: facts,
      history: history,
      prompt: text,
      text: text,
      inputMessageId: userMessage.identity,
      imagePaths: sentImages,
      config: config,
      onPartial: onPartial,
      cancelToken: cancelToken,
      recordFailure: recordFailure,
    );
    _ensureCurrentEpoch(requestEpoch);
    final modelReady = run.config?.isConfigured ?? false;

    var reply = localBuddyReply(
      facts,
      modelMissing: run.modelMissing,
      text: text,
      hasImages: hasImages || earlierImages.isNotEmpty,
    );
    var fromModel = false;
    var stopped = false;
    var interrupted = false;
    var modelFailed = run.modelFailed;
    var notice = run.notice;
    var skipped = <String>[];
    var nextSteps = const <NextStepDraft>[];
    var citations = const <Citation>[];
    final answer = run.answer;

    if (run.notSent) {
      // 图片已经存进讨论，只是这次发不出去；改发文字或重新选图可以继续。
      if (modelReady) {
        reply = '图片已保存在本次讨论中。请重新选择可读取的图片，或输入文字继续。';
      }
      nextSteps = localNextStep(facts, text: text);
    } else if (answer != null) {
      final outcome = interpretModelAnswer(
        answer,
        notice: notice,
        localFallback: () => localBuddyReply(
          facts,
          modelMissing: false,
          text: text,
          hasImages: hasImages || earlierImages.isNotEmpty,
        ),
        fallbackNotice: modelFallbackNotice,
      );
      reply = outcome.text;
      fromModel = outcome.fromModel;
      stopped = outcome.stopped;
      interrupted = outcome.interrupted;
      modelFailed = outcome.modelFailed;
      notice = outcome.notice;
      if (fromModel && !stopped && !interrupted) {
        nextSteps = uniqueById(
          answer.nextSteps,
          (draft) => draft.contentId,
        ).toList();
        citations = await _verifyCitations(
          answer.citations,
          sources: _citationSources(facts, answer.providedSources),
        );
      }
    } else {
      // 模型没配置或调用失败：本地回答已经写好，再补一条本地建议。
      nextSteps = localNextStep(facts, text: text);
    }

    final drafts = fromModel && !stopped && !interrupted
        ? (answer?.memories ?? const <MemoryDraft>[])
        : const <MemoryDraft>[];
    final scope = resolved.scope;
    final memoryItems = <Map<String, Object?>>[];
    final userMemoryDrafts = <({String itemId, MemoryDraft draft})>[];
    var itemIndex = 0;
    for (final draft in uniqueById(drafts, (draft) => draft.contentId)) {
      if (draft.source == MemorySource.user) {
        final content = draft.content.trim();
        if (content.isEmpty) continue;
        // 超过写入长度的记忆不会保存，也不展示卡片，与写入规则保持一致。
        if (content.length > 200) {
          skipped.add('记忆内容超过 200 字，未保存。');
          continue;
        }
        final itemId = 'm${itemIndex++}';
        memoryItems.add({
          'id': itemId,
          'kind': draft.kind.value,
          'content': draft.content,
          'valid_until': draft.validUntil == null
              ? null
              : formatDateTime(draft.validUntil!),
          'status': 'pending',
          'source': 'user',
        });
        userMemoryDrafts.add((itemId: itemId, draft: draft));
      } else {
        // 模型推断的记忆只留在消息里，等用户点“记下”再写入。
        memoryItems.add({
          'id': 'm${itemIndex++}',
          'kind': draft.kind.value,
          'content': draft.content,
          'valid_until': draft.validUntil == null
              ? null
              : formatDateTime(draft.validUntil!),
          'status': 'pending',
          'source': 'inferred',
        });
      }
    }

    // 回答先独立落库；记忆写入另起一个事务，失败时只提示，不回滚正文。
    var assistantMessage = await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      return conversations.append(
        conversationId,
        role: 'assistant',
        content: reply,
        structured: {
          'model': fromModel,
          if (stopped) 'stopped': true,
          if (interrupted) 'interrupted': true,
          if (modelFailed) 'model_failed': true,
          if (modelFailed && run.failure != null)
            'model_failure': run.failure!.name,
          if (modelFailed && notice != null && notice.trim().isNotEmpty)
            'failure_notice': notice.trim(),
          if (memoryItems.isNotEmpty) 'memory_items': memoryItems,
          if (nextSteps.isNotEmpty)
            'next_steps': [
              for (final (index, step) in nextSteps.indexed)
                {
                  'id': 's${index + 1}',
                  'title': step.title,
                  'action': step.action,
                  'end_condition': step.endCondition,
                  'minutes': step.minutes,
                },
            ],
          if (citations.isNotEmpty)
            'citations': [for (final citation in citations) citation.toJson()],
        },
        transaction: txn,
      );
    }, label: '保存回答');

    if (userMemoryDrafts.isNotEmpty) {
      try {
        final refreshed = await transactions.run((txn) async {
          _ensureCurrentEpoch(requestEpoch);
          final applied = await applyMemoryDrafts(
            transactions: transactions,
            memories: memories,
            drafts: [for (final entry in userMemoryDrafts) entry.draft],
            sourceKind: 'user',
            scope: scope,
            transaction: txn,
            clock: policy().clock,
          );
          skipped.addAll(applied.skipped);
          // 每条写入带回原草案，卡片才能对回自己那一条；重复的内容没有写入。
          final byDraft = Map<MemoryDraft, AppliedChange>.identity();
          for (final change in applied.changes) {
            final draft = change.draft;
            if (draft != null) byDraft[draft] = change;
          }
          for (final entry in userMemoryDrafts) {
            final change = byDraft[entry.draft];
            if (change == null) {
              await conversations.setMemoryItemStatus(
                assistantMessage.id,
                entry.itemId,
                status: 'dismissed',
                transaction: txn,
              );
              continue;
            }
            // 用户明确说出的记忆写入后，卡片改为可以撤销的“已记下”。
            await conversations.setMemoryItemStatus(
              assistantMessage.id,
              entry.itemId,
              status: 'accepted',
              commitId: change.commitId,
              transaction: txn,
            );
          }
          return conversations.messageById(
            assistantMessage.id,
            transaction: txn,
          );
        }, label: writeMemoryAction);
        if (refreshed != null) assistantMessage = refreshed;
      } catch (_) {
        // 记忆可撤销，也只是回答的附带写入；失败不拖累已经保存的正文。
        notice = _joinNotices(notice, '记忆保存失败，回答已保存。');
      }
    }

    return ChatResult(
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      reply: reply,
      skipped: skipped,
      nextSteps: nextSteps,
      citations: citations,
      fromModel: fromModel,
      stopped: stopped,
      interrupted: interrupted,
      modelFailed: modelFailed,
      notice: notice,
    );
  }

  /// 用户明确选择的归属；传空表示改回无归属。
  Future<void> setGoal(int conversationId, int? goalId) async {
    if (goalId != null) {
      final goal = await tasks.goalById(goalId);
      if (goal == null) throw ArgumentError('未找到这个目标');
    }
    await conversations.setGoal(conversationId, goalId);
  }

  /// 这次讨论依据的材料与页码；传空表示不再带入材料。
  Future<void> setMaterial(
    int conversationId, {
    required int? materialId,
    int? pageNo,
  }) async {
    if (materialId != null) {
      final page = pageNo == null
          ? null
          : await materials.page(materialId, pageNo);
      if (page == null) throw ArgumentError('未找到这份材料页面');
    }
    await conversations.setMaterial(
      conversationId,
      materialId: materialId,
      pageNo: pageNo,
    );
  }

  /// 结束这次求助；记录保留，之后可以从“记录”重新打开。
  Future<void> end(int conversationId) => conversations.end(conversationId);

  /// 清空一条讨论：消息与讨论记录一起删掉，题目、尝试与记忆不受影响。
  Future<void> clear(int conversationId) async {
    final paths = await conversations.clear(conversationId);
    await cleanupAttachmentPaths(paths);
  }

  /// 接受一条下一步建议：创建学习事项，记下回执，并在原消息里标记已接受。
  ///
  /// 归属只取用户在选择表里明确选中的目标，未选择时 `goalId` 为空；
  /// 这里不写时间块，安排由用户在“安排”页自己排。
  Future<AcceptedSuggestion> acceptNextStep({
    required int conversationId,
    required int messageId,
    required NextStepDraft draft,
    String? stepId,
    int? goalId,
    String? requestId,
  }) {
    return _acceptNextStepOnce(
      conversationId: conversationId,
      messageId: messageId,
      draft: draft,
      stepId: stepId,
      goalId: goalId,
      requestId: requestId,
    );
  }

  Future<AcceptedSuggestion> _acceptNextStepOnce({
    required int conversationId,
    required int messageId,
    required NextStepDraft draft,
    String? stepId,
    int? goalId,
    String? requestId,
  }) async {
    try {
      return await transactions.run(
        (txn) async {
          final record = await conversations.byId(
            conversationId,
            transaction: txn,
          );
          if (record == null) throw StateError('未找到这条讨论');
          if (goalId != null) {
            final goal = await tasks.goalById(goalId, transaction: txn);
            if (goal == null) throw ArgumentError('未找到这个目标');
            if (!goal.active) throw ArgumentError('这个目标已暂停，请先恢复后再添加安排');
          }

          final message = await conversations.messageById(
            messageId,
            transaction: txn,
          );
          if (message == null || message.conversationId != conversationId) {
            throw StateError('未找到这条建议');
          }
          final accepted = _acceptedIds(message.structured);
          final acceptedTitles = _acceptedTitles(message.structured);
          if (stepId != null
              ? accepted.contains(stepId)
              : acceptedTitles.contains(draft.title)) {
            throw StateError('这条建议已加入安排');
          }
          final dismissed = _dismissedIds(message.structured);
          final dismissedTitles = _dismissedTitles(message.structured);
          if (stepId != null
              ? dismissed.contains(stepId)
              : dismissedTitles.contains(draft.title)) {
            throw StateError('这条建议已暂不安排');
          }

          final id = await tasks.createItem(
            title: draft.title,
            goalId: goalId,
            conversationId: conversationId,
            note: _stepNote(draft),
            estMinutes: draft.minutes,
            source: 'ai',
            origin: {
              'conversation_id': conversationId,
              'message_id': messageId,
              'step_id': ?stepId,
            },
            transaction: txn,
          );
          final commitId = await txn.requireCommitId();
          await conversations.markNextStepAccepted(
            messageId,
            draft.title,
            stepId: stepId,
            commitId: commitId,
            transaction: txn,
          );
          final item = await tasks.byId(id, transaction: txn);
          if (item == null) throw StateError('学习事项保存失败');
          return AcceptedSuggestion(item: item, commitId: commitId);
        },
        label: acceptNextStepAction,
        requestId: requestId,
      );
    } on RevisionDuplicateRequest catch (error) {
      // 同一条建议已经接受；重试按消息与建议编号找回原事项，不再新建第二条。
      final item = stepId == null
          ? await tasks.byConversationAndTitle(conversationId, draft.title)
          : await tasks.byConversationAndStep(conversationId, stepId);
      if (item != null) {
        return AcceptedSuggestion(item: item, commitId: error.commit.id);
      }
      rethrow;
    }
  }

  /// 消息里还没有被接受的下一步建议。
  static List<PendingSuggestion> pendingSuggestions(
    List<ChatMessage> messages,
  ) {
    final result = <PendingSuggestion>[];
    for (final message in messages) {
      if (message.role != 'assistant') continue;
      final structured = message.structured;
      if (structured == null) continue;
      final acceptedTitles = _acceptedTitles(structured);
      final dismissedTitles = _dismissedTitles(structured);
      final acceptedIds = _acceptedIds(structured);
      final dismissedIds = _dismissedIds(structured);
      final rawSteps = structured['next_steps'];
      if (rawSteps is! List) continue;
      for (final (index, item) in rawSteps.indexed) {
        if (item is! Map) continue;
        final title = item['title'];
        if (title is! String || title.trim().isEmpty) continue;
        final stepId = item['id'] is String && (item['id'] as String).isNotEmpty
            ? item['id'] as String
            : 's${index + 1}';
        final handled = acceptedIds.isNotEmpty || dismissedIds.isNotEmpty
            ? acceptedIds.contains(stepId) || dismissedIds.contains(stepId)
            : acceptedTitles.contains(title.trim()) ||
                  dismissedTitles.contains(title.trim());
        if (handled) continue;
        result.add(
          PendingSuggestion(
            messageId: message.id,
            stepId: stepId,
            draft: NextStepDraft(
              title: title.trim(),
              action: item['action'] is String
                  ? (item['action'] as String).trim()
                  : null,
              endCondition: item['end_condition'] is String
                  ? (item['end_condition'] as String).trim()
                  : null,
              minutes: item['minutes'] is int ? item['minutes'] as int : null,
            ),
          ),
        );
      }
    }
    return result;
  }

  Future<void> dismissNextStep({
    required int conversationId,
    required int messageId,
    required String title,
    String? stepId,
  }) async {
    final message = await conversations.messageById(messageId);
    if (message == null || message.conversationId != conversationId) {
      throw StateError('未找到这条建议');
    }
    final accepted = stepId == null
        ? _acceptedTitles(message.structured).contains(title)
        : _acceptedIds(message.structured).contains(stepId);
    if (accepted) {
      throw StateError('这条建议已经加入安排');
    }
    await conversations.markNextStepDismissed(messageId, title, stepId: stepId);
  }

  /// 消息里还没有处理的记忆，以及已经写入、仍可撤销的记忆。
  Future<List<MemoryItemView>> memoryItemsFromMessages(
    List<ChatMessage> messages,
  ) async {
    final stored = <({int messageId, _StoredMemoryItem item})>[];
    for (final message in messages) {
      if (message.role != 'assistant') continue;
      for (final item in _storedMemoryItems(message.structured)) {
        stored.add((messageId: message.id, item: item));
      }
    }
    if (stored.isEmpty) return const [];
    final commitIds = <int>{
      for (final entry in stored)
        if (entry.item.status == 'accepted' && entry.item.commitId != null)
          entry.item.commitId!,
    };
    final active = commitIds.isEmpty
        ? const <int>{}
        : await revisions.activeCommits(commitIds);
    final result = <MemoryItemView>[];
    for (final entry in stored) {
      final item = entry.item;
      if (item.status == 'dismissed') continue;
      if (item.status == 'accepted') {
        if (item.commitId == null || !active.contains(item.commitId)) {
          continue;
        }
      } else if (item.status != 'pending') {
        continue;
      }
      result.add(
        MemoryItemView(
          ownerId: entry.messageId,
          itemId: item.id,
          draft: MemoryDraft(
            kind: item.kind,
            content: item.content,
            validUntil: item.validUntil,
            source: item.source,
          ),
          status: item.status,
          commitId: item.commitId,
        ),
      );
    }
    return result;
  }

  /// 用户点“记下”后才写入推断的记忆；重复或过长时不写，卡片随之收起。
  Future<AcceptedMemory> acceptMemoryItem({
    required int conversationId,
    required int messageId,
    required String itemId,
  }) async {
    // 范围在事务外按同一条规则解析；写入时不再读一次记录上的归属。
    final resolved = await memoryScope.resolve(conversationId);
    return transactions.run((txn) async {
      final record = await conversations.byId(conversationId, transaction: txn);
      if (record == null) throw StateError('未找到这条讨论');
      final message = await conversations.messageById(
        messageId,
        transaction: txn,
      );
      if (message == null || message.conversationId != conversationId) {
        throw StateError('未找到这条记忆');
      }
      final stored = _storedMemoryItems(message.structured);
      _StoredMemoryItem? item;
      for (final entry in stored) {
        if (entry.id == itemId) {
          item = entry;
          break;
        }
      }
      if (item == null) throw StateError('未找到这条记忆');
      if (item.status != 'pending') throw StateError('这条记忆已经处理');

      return confirmMemoryDraft(
        transaction: txn,
        transactions: transactions,
        memories: memories,
        draft: MemoryDraft(
          kind: item.kind,
          content: item.content,
          validUntil: item.validUntil,
        ),
        sourceKind: item.source == MemorySource.user ? 'user' : 'message',
        sourceId: messageId,
        scope: resolved.scope,
        clock: policy().clock,
        recordStatus: (status, commitId) => conversations.setMemoryItemStatus(
          messageId,
          itemId,
          status: status,
          commitId: commitId,
          transaction: txn,
        ),
      );
    }, label: confirmMemoryAction);
  }

  /// 用户点“不记”后收起卡片；记忆没有写入，不需要撤销。
  Future<void> dismissMemoryItem({
    required int conversationId,
    required int messageId,
    required String itemId,
  }) async {
    final message = await conversations.messageById(messageId);
    if (message == null || message.conversationId != conversationId) {
      throw StateError('未找到这条记忆');
    }
    _StoredMemoryItem? item;
    for (final entry in _storedMemoryItems(message.structured)) {
      if (entry.id == itemId) {
        item = entry;
        break;
      }
    }
    if (item == null) throw StateError('未找到这条记忆');
    if (item.status != 'pending') throw StateError('这条记忆已经处理');
    await conversations.setMemoryItemStatus(
      messageId,
      itemId,
      status: 'dismissed',
    );
  }

  Future<List<AppliedChange>> changesFromMessages(
    List<ChatMessage> messages,
  ) async {
    final changes = <AppliedChange>[];
    final receipts = <({int commitId, String text})>[];
    for (final message in messages) {
      final raw = message.structured?['operations'];
      if (raw is! List) continue;
      for (final item in raw) {
        if (item is! Map ||
            item['commit_id'] is! int ||
            item['text'] is! String) {
          continue;
        }
        receipts.add((
          commitId: item['commit_id'] as int,
          text: item['text'] as String,
        ));
      }
    }
    if (receipts.isEmpty) return const [];
    final active = await revisions.activeCommits(
      receipts.map((item) => item.commitId),
    );
    for (final receipt in receipts) {
      if (!active.contains(receipt.commitId)) continue;
      changes.add(
        AppliedChange(commitId: receipt.commitId, text: receipt.text),
      );
    }
    return changes;
  }

  /// 消息里展示用的引用；未核对的条目由界面标出。
  static List<Citation> citationsOf(ChatMessage message) {
    final structured = message.structured;
    if (structured == null) return const [];
    final raw = structured['citations'];
    if (raw is! List) return const [];
    return [
      for (final item in raw) Citation.fromJson(item, materialTitles: const {}),
    ];
  }

  /// 本轮真正提供过的材料页：当前页、检索到的其他页与工具补读到的页。
  ///
  /// 引用核验只认这份来源表，模型自己写出的材料编号不会因为库里恰好有这一页
  /// 就被接受；同一页以第一次提供的原文为准。
  static Map<(int, int), CitationSource> _citationSources(
    BuddyContext facts,
    List<CitationSource> provided,
  ) {
    final sources = <(int, int), CitationSource>{};
    void add(
      int materialId,
      int pageNo,
      String content, {
      String? title,
      String? version,
      bool isDocx = false,
    }) {
      sources.putIfAbsent(
        (materialId, pageNo),
        () => CitationSource(
          materialId: materialId,
          pageNo: pageNo,
          content: content,
          materialTitle: title,
          sourceVersion: version,
          isDocx: isDocx,
        ),
      );
    }

    if (facts.materialPage case final page?) {
      add(
        page.materialId,
        page.pageNo,
        page.content,
        title: facts.material?.title,
        isDocx: facts.material?.isDocx ?? false,
      );
    }
    for (final hit in facts.materialHits) {
      add(
        hit.materialId,
        hit.pageNo,
        hit.content,
        title: hit.materialTitle,
        isDocx: hit.isDocx,
      );
    }
    for (final source in provided) {
      add(
        source.materialId,
        source.pageNo,
        source.content,
        title: source.materialTitle,
        version: source.sourceVersion,
        isDocx: source.isDocx,
      );
    }
    return sources;
  }

  Future<List<Citation>> _verifyCitations(
    List<CitationDraft> drafts, {
    required Map<(int, int), CitationSource> sources,
  }) async {
    final pages = <(int, int), MaterialPage?>{};
    final result = <Citation>[];
    for (final draft in uniqueById(drafts, (draft) => draft.contentId)) {
      final key = (draft.materialId, draft.pageNo);
      final source = sources[key];
      // 本轮没有提供过这一页，或者已经越界，不进入引用。
      if (source == null) continue;
      if (!pages.containsKey(key)) {
        pages[key] = await materials.page(draft.materialId, draft.pageNo);
      }
      final page = pages[key];
      // 来源在本轮读取之后又被更正或删除时，旧原文不再作为核对依据。
      if (page == null ||
          _normalize(page.content) != _normalize(source.content)) {
        continue;
      }
      final verified = _normalize(page.content)
          .contains(_normalize(draft.quote));
      result.add(
        Citation(
          materialId: draft.materialId,
          pageNo: draft.pageNo,
          quote: draft.quote,
          verified: verified,
          materialTitle: source.materialTitle,
          isDocx: source.isDocx,
        ),
      );
    }
    return result;
  }

  Future<LlmConfig?> _configOrNull() async {
    try {
      return await ai.config();
    } catch (_) {
      return null;
    }
  }

  /// 建议里的动作与完成条件合成一段说明；都没有时为空。
  static String? _stepNote(NextStepDraft draft) {
    final parts = [draft.action, draft.endCondition]
        .map((value) => value?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? null : parts.join('；');
  }

  static String _joinNotices(String? first, String second) =>
      first == null ? second : '$first $second';

  void _ensureCurrentEpoch(int expected) {
    if (dataEpoch() != expected) {
      throw StateError('数据已恢复或清空，请重新打开这条讨论后再发送。');
    }
  }

  static String _titleFor(String text) {
    final line = text.split('\n').first.trim();
    if (line.isEmpty) return '图片求助';
    final runes = line.runes.toList(growable: false);
    if (runes.length <= 24) return line;
    return '${String.fromCharCodes(runes.take(24))}…';
  }

  static List<String> _cleanPaths(List<String> paths) => {
    for (final path in paths)
      if (path.trim().isNotEmpty) path.trim(),
  }.toList(growable: false);

  /// 事务外读图片、算哈希并补界面缓存；事务内只写附件对象与业务行。
  Future<_IngestedAttachments> _ingest(List<String> paths) async {
    if (paths.isEmpty) return const _IngestedAttachments([], []);
    final refs = <String>{};
    final pending = <String, Uint8List>{};
    for (final path in paths) {
      try {
        final bytes = await File(
          AssetStore.isHash(path) ? cache.pathFor(path) : path,
        ).readAsBytes();
        final hash = AssetStore.hashBytes(bytes);
        if (!pending.containsKey(hash)) {
          await cache.write(hash, bytes);
          pending[hash] = bytes;
        }
        refs.add(hash);
      } catch (_) {
        // 读不到的文件仍保留原引用，界面会提示本机没有这张原图。
        refs.add(path);
      }
    }
    return _IngestedAttachments(refs.toList(growable: false), [
      for (final entry in pending.entries)
        (hash: entry.key, bytes: entry.value),
    ]);
  }

  static Set<String> _acceptedTitles(Map<String, Object?>? structured) =>
      _stringState(structured, 'accepted');

  static Set<String> _dismissedTitles(Map<String, Object?>? structured) =>
      _stringState(structured, 'dismissed');

  static Set<String> _acceptedIds(Map<String, Object?>? structured) =>
      _stringState(structured, 'accepted_ids');

  static Set<String> _dismissedIds(Map<String, Object?>? structured) =>
      _stringState(structured, 'dismissed_ids');

  static Set<String> _stringState(
    Map<String, Object?>? structured,
    String key,
  ) {
    if (structured == null) return const <String>{};
    final raw = structured[key];
    if (raw is! List) return const <String>{};
    return {
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    };
  }

  static String _normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').trim();

  static List<_StoredMemoryItem> _storedMemoryItems(
    Map<String, Object?>? structured,
  ) {
    if (structured == null) return const [];
    final raw = structured['memory_items'];
    if (raw is! List) return const [];
    final result = <_StoredMemoryItem>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = item['id'];
      final kind = item['kind'];
      final content = item['content'];
      final status = item['status'];
      if (id is! String || kind is! String || content is! String) continue;
      if (status is! String || content.trim().isEmpty) continue;
      result.add(
        _StoredMemoryItem(
          id: id,
          kind: MemoryKind.fromValue(kind),
          content: content.trim(),
          validUntil: _parseMemoryTime(item['valid_until']),
          status: status,
          source: item['source'] == 'user'
              ? MemorySource.user
              : MemorySource.inferred,
          commitId: item['commit_id'] is int ? item['commit_id'] as int : null,
        ),
      );
    }
    return result;
  }

  static DateTime? _parseMemoryTime(Object? value) {
    if (value is! String || value.trim().isEmpty || value == 'null') {
      return null;
    }
    return DateTime.tryParse(value.trim());
  }
}

class _StoredMemoryItem {
  const _StoredMemoryItem({
    required this.id,
    required this.kind,
    required this.content,
    required this.status,
    required this.source,
    this.validUntil,
    this.commitId,
  });

  final String id;
  final MemoryKind kind;
  final String content;
  final String status;
  final MemorySource source;
  final DateTime? validUntil;
  final int? commitId;
}

int _zeroDataEpoch() => 0;

class _IngestedAttachments {
  const _IngestedAttachments(this.refs, this.pending);

  final List<String> refs;
  final List<({String hash, Uint8List bytes})> pending;
}
