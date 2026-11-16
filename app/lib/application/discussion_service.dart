import 'dart:io';
import 'dart:typed_data';

import '../ai/ai_chat_service.dart';
import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../data/db/write_transactions.dart';
import '../data/revisions/asset_store.dart';
import '../data/revisions/revision_actions.dart';
import '../domain/rules/notices.dart';
import '../data/revisions/revision_engine.dart';
import '../data/revisions/revision_service.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/chat_message_payload.dart';
import '../domain/models/evidence.dart';
import '../domain/models/material.dart';
import '../domain/models/memory.dart';
import '../domain/models/study.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/content_identity.dart';
import 'buddy_fallback.dart';
import 'buddy_actions.dart';
import 'buddy_answer.dart';
import 'command_ids.dart';
import 'context_request.dart';
import 'context_service.dart';
import 'memory_scope_service.dart';
import 'memory_view.dart';
import 'answer_outcome.dart';
import 'service_runtime.dart';

import '../domain/rules/text.dart';

/// 一次求助的结果：两条消息、引用与要展示的下一步建议。
///
/// 记忆写入后的卡片状态与可撤销回执都从消息里读，不在结果里另带一份。
class ChatResult {
  const ChatResult({
    required this.userMessage,
    required this.assistantMessage,
    required this.outcome,
    this.skipped = const [],
    this.nextSteps = const [],
    this.citations = const [],
  });

  final ChatMessage userMessage;
  final ChatMessage assistantMessage;

  /// 这次回答的正文、来源与中断情况。
  final AnswerOutcome outcome;

  /// 正文；停止或中断时是已经生成的部分。
  String get reply => outcome.text;
  bool get fromModel => outcome.fromModel;
  bool get stopped => outcome.stopped;
  bool get interrupted => outcome.interrupted;
  bool get modelFailed => outcome.modelFailed;

  /// 这次回答需要界面区分的情况；提示与恢复入口都按它决定。
  List<Notice> get notices => outcome.notices;

  final List<String> skipped;
  final List<NextStepDraft> nextSteps;

  /// 本次回答引用的材料页；逐字核对不上的条目为未核实。
  final List<Citation> citations;
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

/// 讨论页的一屏：记录本身、目标列表、已经读到的消息，以及从这批消息读出的
/// 下一步建议、记忆卡片与回答写下的改动。
///
/// 消息从旧到新排列；按“读取较早讨论”读出来的更早几页作为读取的输入交给
/// 服务，由服务接在最近一页之前并按编号去重，页面只按顺序显示。
class ConversationView {
  const ConversationView({
    required this.record,
    required this.goals,
    required this.messages,
    required this.hasOlder,
    this.pending = const [],
    this.memoryItems = const [],
    this.changes = const [],
  });

  final ConversationRecord? record;
  final List<LearningGoal> goals;
  final List<ChatMessage> messages;

  /// 读到的这一页之前是否还有更早的消息。
  final bool hasOlder;

  final List<PendingSuggestion> pending;
  final List<MemoryItemView> memoryItems;
  final List<AppliedChange> changes;
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
    required this.runtime,
    required this.transactions,
    required this.cleanupAttachmentPaths,
    AssetStore? assets,
    AttachmentCache? cache,
  }) : assets = assets ?? AssetStore(),
       cache = cache ?? AttachmentCache(filesDir: () => runtime.filesDir);

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
  final ServiceRuntime runtime;

  /// 图片字节按哈希写入同一个库；业务行只保存哈希引用。
  final AssetStore assets;
  final AttachmentCache cache;

  /// 写入记录与撤销都经这份连接；与仓库共用同一个库。
  final WriteTransactions transactions;

  final Future<void> Function(Iterable<String> paths) cleanupAttachmentPaths;

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

  /// 讨论页读到的表：任一表写入之后整屏重读一次（ADR-0014）。
  ///
  /// 记录行自身还会补出材料标题、是否有作答与是否有草稿，因此 `attempt` 与
  /// `material` 也在这里；目标选择读 `learning_goal`。
  static const Set<String> _conversationTables = {
    'conversation',
    'message',
    'attempt',
    'material',
    'learning_goal',
  };

  /// 跟随写入更新的讨论一屏。
  ///
  /// [olderMessages] 是页面已经按“读取较早讨论”读出来的更早消息，读取时与最近
  /// 一页按编号去重合并，因此建议、记忆卡片与回执也覆盖已经翻到的部分。
  Stream<ConversationView> watchConversation(
    int id, {
    List<ChatMessage> olderMessages = const [],
  }) => runtime.watch(
    tables: _conversationTables,
    read: () => conversationView(id, olderMessages: olderMessages),
  );

  /// 读一次讨论一屏：记录、目标与最近一页消息互不依赖，同时读取，再从合并后
  /// 的消息里读出下一步建议、记忆卡片与回执。
  Future<ConversationView> conversationView(
    int id, {
    List<ChatMessage> olderMessages = const [],
  }) async {
    final (record, goals, page) = await (
      conversations.byId(id),
      tasks.activeGoals(),
      conversations.historyPage(id),
    ).wait;
    final messages = mergeOlderMessages(olderMessages, page.messages);
    final (memoryItems, changes) = await (
      memoryItemsFromMessages(messages),
      changesFromMessages(messages),
    ).wait;
    return ConversationView(
      record: record,
      goals: goals,
      messages: messages,
      hasOlder: page.hasOlder,
      pending: pendingSuggestions(messages),
      memoryItems: memoryItems,
      changes: changes,
    );
  }

  /// 把更早读到的消息接在最近一页之前，按编号去重。
  ///
  /// 同一条讨论里消息编号随写入递增，较早读出的几页都在最近一页之前；两页在
  /// 记录变长时可能有重叠，去重保证同一条消息只显示一次。
  static List<ChatMessage> mergeOlderMessages(
    List<ChatMessage> older,
    List<ChatMessage> latest,
  ) {
    final seen = <int>{};
    return [
      for (final message in older)
        if (seen.add(message.id)) message,
      for (final message in latest)
        if (seen.add(message.id)) message,
    ];
  }

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
        ? EntryKind.photo
        : (paths.isEmpty ? EntryKind.text : EntryKind.textPhoto);
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
    final requestEpoch = runtime.dataEpoch;
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
        role: MessageRole.user,
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
    final requestEpoch = runtime.dataEpoch;
    final record = await conversations.byId(conversationId);
    if (record == null) throw StateError('未找到这条讨论');
    if (!record.open) await conversations.reopen(conversationId);
    final read = await readModelConfig(
      ai,
      recordFailure: runtime.recordFailure,
    );
    final config = read.config;
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
      ContextRequest(
        mode: BuddyMode.chat,
        goalId: resolved.goalId,
        materialId: record.materialId,
        pageNo: record.pageNo,
        conversationId: conversationId,
        query: text,
        broughtIdentities: broughtIdentities,
      ),
    );
    // 用户只追问文字时，把这条讨论里最近一次带图消息的原图一起发给模型；
    // 历史消息本身没有图片字段，只放占位符会让模型看不到题目原图。
    final earlierImages = imageRefs.isNotEmpty
        ? const <String>[]
        : (history.reversed
                  .where(
                    (message) =>
                        message.role == MessageRole.user && message.hasImages,
                  )
                  .firstOrNull
                  ?.imagePaths ??
              const <String>[]);
    final sentImages = imageRefs.isNotEmpty ? imageRefs : earlierImages;
    final run = await askBuddyModel(
      ai: ai,
      filesDir: () => runtime.filesDir,
      context: facts,
      history: history,
      prompt: text,
      text: text,
      inputMessageId: userMessage.identity,
      imagePaths: sentImages,
      config: config,
      onPartial: onPartial,
      cancelToken: cancelToken,
      recordFailure: runtime.recordFailure,
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
    var notices = run.notices;
    String? detail;
    var failure = run.failure;
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
        notices: notices,
        omittedImages: run.omittedImages,
        failure: failure,
        localFallback: () => localBuddyReply(
          facts,
          modelMissing: false,
          text: text,
          hasImages: hasImages || earlierImages.isNotEmpty,
        ),
      );
      reply = outcome.text;
      fromModel = outcome.fromModel;
      stopped = outcome.stopped;
      interrupted = outcome.interrupted;
      modelFailed = outcome.modelFailed;
      notices = outcome.notices;
      detail = outcome.detail;
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
    final memoryItems = <MemoryDraft>[];
    final userMemoryDrafts = <({String itemId, MemoryDraft draft})>[];
    var itemIndex = 0;
    for (final draft in uniqueById(drafts, (draft) => draft.contentId)) {
      if (draft.content.trim().isEmpty) continue;
      if (draft.source == MemorySource.user && draft.tooLong) {
        // 超过写入长度的记忆不会保存，也不展示卡片，与写入规则保持一致。
        skipped.add('记忆内容超过 $memoryContentLimit 字，未保存。');
        continue;
      }
      final itemId = 'm${itemIndex++}';
      final card = MemoryDraft(
        id: itemId,
        kind: draft.kind,
        content: draft.content,
        validUntil: draft.validUntil,
        source: draft.source,
      );
      memoryItems.add(card);
      if (card.source == MemorySource.user) {
        userMemoryDrafts.add((itemId: itemId, draft: card));
      }
    }

    // 回答先独立落库；记忆写入另起一个事务，失败时只提示，不回滚正文。
    var assistantMessage = await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      return conversations.append(
        conversationId,
        role: MessageRole.assistant,
        content: reply,
        payload: ChatMessagePayload(
          fromModel: fromModel,
          stopped: stopped,
          interrupted: interrupted,
          modelFailed: modelFailed,
          failureName: modelFailed ? failure?.name : null,
          notices: notices,
          memoryItems: memoryItems,
          nextSteps: [
            for (final (index, step) in nextSteps.indexed)
              ChatNextStep(
                id: 's${index + 1}',
                title: step.title,
                action: step.action,
                endCondition: step.endCondition,
                minutes: step.minutes,
              ),
          ],
          citations: citations,
        ),
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
            sourceKind: MemorySourceKind.user,
            scope: scope,
            transaction: txn,
            clock: runtime.policy.clock,
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
                status: MemoryCardStatus.dismissed,
                transaction: txn,
              );
              continue;
            }
            // 用户明确说出的记忆写入后，卡片改为可以撤销的“已记下”。
            await conversations.setMemoryItemStatus(
              assistantMessage.id,
              entry.itemId,
              status: MemoryCardStatus.accepted,
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
        notices = [...notices, Notice.memorySaveFailed];
      }
    }

    return ChatResult(
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      outcome: AnswerOutcome(
        text: reply,
        fromModel: fromModel,
        stopped: stopped,
        interrupted: interrupted,
        modelFailed: modelFailed,
        notices: notices,
        detail: detail,
        omittedImages: run.omittedImages,
        failure: failure,
      ),
      skipped: skipped,
      nextSteps: nextSteps,
      citations: citations,
    );
  }

  /// 用户明确选择的归属；传空表示改回无归属。
  Future<WriteResult> setGoal(int conversationId, int? goalId) async {
    if (goalId != null) {
      final goal = await tasks.goalById(goalId);
      if (goal == null) throw ArgumentError('未找到这个目标');
    }
    return transactions.run((txn) async {
      await conversations.setGoal(conversationId, goalId);
      return txn.result();
    }, label: '修改讨论归属');
  }

  /// 这次讨论依据的材料与页码；传空表示不再带入材料。
  Future<WriteResult> setMaterial(
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
    return transactions.run((txn) async {
      await conversations.setMaterial(
        conversationId,
        materialId: materialId,
        pageNo: pageNo,
      );
      return txn.result();
    }, label: '修改讨论材料');
  }

  /// 结束这次求助；记录保留，之后可以从“记录”重新打开。
  Future<WriteResult> end(int conversationId) => transactions.run((txn) async {
    await conversations.end(conversationId);
    return txn.result();
  }, label: '结束求助');

  /// 清空一条讨论：消息与讨论记录一起删掉，题目、尝试与记忆不受影响。
  Future<WriteResult> clear(int conversationId) async {
    final done = await transactions.run((txn) async {
      final paths = await conversations.clear(conversationId, transaction: txn);
      return (paths: paths, result: await txn.result());
    }, label: '清空学习记录');
    await cleanupAttachmentPaths(done.paths);
    return done.result;
  }

  /// 接受一条下一步建议：创建学习事项，记下回执，并在原消息里标记已接受。
  ///
  /// 归属只取用户在选择表里明确选中的目标，未选择时 `goalId` 为空；
  /// 这里不写时间块，安排由用户在“安排”页自己排。编号按消息与建议生成，
  /// 同一条建议连点两次只形成一条提交。
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
      requestId:
          requestId ??
          commandId('accept-suggestion', [
            conversationId,
            messageId,
            stepId ?? draft.title,
          ]),
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
          final payload = message.payload ?? const ChatMessagePayload();
          final accepted = stepId != null
              ? payload.acceptedStepIds.contains(stepId)
              : payload.acceptedTitles.contains(draft.title);
          if (accepted) {
            throw StateError('这条建议已加入安排');
          }
          final dismissed = stepId != null
              ? payload.dismissedStepIds.contains(stepId)
              : payload.dismissedTitles.contains(draft.title);
          if (dismissed) {
            throw StateError('这条建议已暂不安排');
          }

          final id = await tasks.createItem(
            title: draft.title,
            goalId: goalId,
            conversationId: conversationId,
            note: _stepNote(draft),
            estMinutes: draft.minutes,
            source: PlanItemSource.ai,
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
      if (message.role != MessageRole.assistant) continue;
      final payload = message.payload;
      if (payload == null) continue;
      for (final step in payload.nextSteps) {
        if (payload.isStepHandled(step.id, step.title)) continue;
        result.add(
          PendingSuggestion(
            messageId: message.id,
            stepId: step.id,
            draft: NextStepDraft(
              title: step.title,
              action: step.action,
              endCondition: step.endCondition,
              minutes: step.minutes,
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
    final payload = message.payload ?? const ChatMessagePayload();
    final accepted = stepId == null
        ? payload.acceptedTitles.contains(title)
        : payload.acceptedStepIds.contains(stepId);
    if (accepted) {
      throw StateError('这条建议已经加入安排');
    }
    await conversations.markNextStepDismissed(messageId, title, stepId: stepId);
  }

  /// 消息里还没有处理的记忆，以及已经写入、仍可撤销的记忆。
  Future<List<MemoryItemView>> memoryItemsFromMessages(
    List<ChatMessage> messages,
  ) async {
    final stored = <({int messageId, MemoryDraft draft})>[];
    for (final message in messages) {
      if (message.role != MessageRole.assistant) continue;
      for (final item
          in message.payload?.memoryItems ?? const <MemoryDraft>[]) {
        stored.add((messageId: message.id, draft: item));
      }
    }
    if (stored.isEmpty) return const [];
    final commitIds = <int>{
      for (final entry in stored)
        if (entry.draft.status == MemoryCardStatus.accepted &&
            entry.draft.commitId != null)
          entry.draft.commitId!,
    };
    final active = commitIds.isEmpty
        ? const <int>{}
        : await revisions.activeCommits(commitIds);
    final result = <MemoryItemView>[];
    for (final entry in stored) {
      final item = entry.draft;
      if (item.status == MemoryCardStatus.dismissed) continue;
      if (item.status == MemoryCardStatus.accepted) {
        if (item.commitId == null || !active.contains(item.commitId)) {
          continue;
        }
      } else if (item.status != MemoryCardStatus.pending) {
        continue;
      }
      result.add(MemoryItemView(ownerId: entry.messageId, draft: item));
    }
    return result;
  }

  /// 用户点“记下”后才写入推断的记忆；重复或过长时不写，卡片随之收起。
  ///
  /// 编号按消息与卡片编号生成，同一张卡连点两次只形成一条提交。
  Future<AcceptedMemory> acceptMemoryItem({
    required int conversationId,
    required int messageId,
    required String itemId,
    String? requestId,
  }) async {
    // 范围在事务外按同一条规则解析；写入时不再读一次记录上的归属。
    final resolved = await memoryScope.resolve(conversationId);
    try {
      return await transactions.run(
        (txn) async {
          final record = await conversations.byId(
            conversationId,
            transaction: txn,
          );
          if (record == null) throw StateError('未找到这条讨论');
          final message = await conversations.messageById(
            messageId,
            transaction: txn,
          );
          if (message == null || message.conversationId != conversationId) {
            throw StateError('未找到这条记忆');
          }
          final item = message.payload?.memoryItem(itemId);
          if (item == null) throw StateError('未找到这条记忆');
          if (item.status == MemoryCardStatus.accepted) {
            // 同一张卡连点两次：上一次已经写入，按重试返回，不再形成提交。
            return const AcceptedMemory(applied: true, notice: '这条记忆已经处理。');
          }
          if (item.status != MemoryCardStatus.pending) {
            throw StateError('这条记忆已经处理');
          }

          return confirmMemoryDraft(
            transaction: txn,
            transactions: transactions,
            memories: memories,
            draft: item,
            sourceKind: item.source == MemorySource.user
                ? MemorySourceKind.user
                : MemorySourceKind.message,
            sourceId: messageId,
            scope: resolved.scope,
            clock: runtime.policy.clock,
            recordStatus: (status, commitId) =>
                conversations.setMemoryItemStatus(
                  messageId,
                  itemId,
                  status: status,
                  commitId: commitId,
                  transaction: txn,
                ),
          );
        },
        label: confirmMemoryAction,
        requestId: requestId ?? commandId('accept-memory', [messageId, itemId]),
      );
    } on RevisionDuplicateRequest {
      // 同一张卡已经写入；重试按库里的状态返回，不再重复写记忆。
      final message = await conversations.messageById(messageId);
      final item = message?.payload?.memoryItem(itemId);
      return AcceptedMemory(
        applied: item?.status == MemoryCardStatus.accepted,
        notice: '这条记忆已经处理。',
      );
    }
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
    final item = message.payload?.memoryItem(itemId);
    if (item == null) throw StateError('未找到这条记忆');
    if (item.status != MemoryCardStatus.pending) {
      throw StateError('这条记忆已经处理');
    }
    await conversations.setMemoryItemStatus(
      messageId,
      itemId,
      status: MemoryCardStatus.dismissed,
    );
  }

  Future<List<AppliedChange>> changesFromMessages(
    List<ChatMessage> messages,
  ) async {
    final receipts = <ChatOperationReceipt>[
      for (final message in messages) ...?message.payload?.operations,
    ];
    if (receipts.isEmpty) return const [];
    final active = await revisions.activeCommits(
      receipts.map((item) => item.commitId),
    );
    return [
      for (final receipt in receipts)
        if (active.contains(receipt.commitId))
          AppliedChange(commitId: receipt.commitId, text: receipt.text),
    ];
  }

  /// 消息里展示用的引用；未核对的条目由界面标出。
  static List<Citation> citationsOf(ChatMessage message) =>
      message.payload?.citations ?? const [];

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

  /// 建议里的动作与完成条件合成一段说明；都没有时为空。
  static String? _stepNote(NextStepDraft draft) {
    final parts = [draft.action, draft.endCondition]
        .map((value) => value?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? null : parts.join('；');
  }

  void _ensureCurrentEpoch(int expected) {
    if (runtime.dataEpoch != expected) {
      throw StateError('数据已恢复或清空，请重新打开这条讨论后再发送。');
    }
  }

  static String _titleFor(String text) {
    final line = text.split('\n').first.trim();
    if (line.isEmpty) return '图片求助';
    return truncateCodePoints(line, 24);
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

  static String _normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').trim();
}

class _IngestedAttachments {
  const _IngestedAttachments(this.refs, this.pending);

  final List<String> refs;
  final List<({String hash, Uint8List bytes})> pending;
}
