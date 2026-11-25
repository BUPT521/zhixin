import '../ai/ai_chat_service.dart';
import '../ai/llm_client.dart';
import '../ai/buddy_prompts.dart';
import '../ai/llm_config.dart';
import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/revisions/revision_engine.dart';
import '../data/revisions/revision_service.dart';
import '../data/repository/assessment_repository.dart';
import '../data/repository/attempt_repository.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/schedule_repository.dart';
import '../data/repository/study_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/assessment.dart';
import '../domain/models/buddy_protocol.dart';
import '../domain/models/chat_message_payload.dart';
import '../domain/models/memory.dart';
import '../domain/models/question.dart';
import '../domain/models/study.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/content_identity.dart';
import '../domain/rules/notices.dart';
import 'buddy_fallback.dart';
import 'buddy_actions.dart';
import 'buddy_answer.dart';
import 'attachment_service.dart';
import '../../domain/rules/uuid_v7.dart';
import 'context_request.dart';
import 'context_service.dart';
import 'memory_scope_service.dart';
import 'memory_view.dart';
import 'answer_outcome.dart';
import 'service_runtime.dart';
import 'used_pages.dart';

/// 一道题的当前状态：原题、尝试、一条未提交尝试，以及学习页要显示的判断与
/// 记忆建议。
class QuestionView {
  const QuestionView({
    required this.question,
    required this.attempts,
    this.openAttempt,
    this.recentMessages = const [],
    this.assessments = const {},
    this.memoryItems = const [],
  });

  final Question question;
  final List<Attempt> attempts;
  final Attempt? openAttempt;

  /// 这道题最近几条讨论消息；学习页在题目下方显示刚才的对话。
  final List<ChatMessage> recentMessages;

  /// 每次尝试的判断，按尝试编号分组；学习页在历次尝试里逐条显示。
  final Map<String, List<Assessment>> assessments;

  /// 当前未提交尝试上的记忆建议；已经写入的只保留仍可撤销的那几条。
  final List<MemoryItemView> memoryItems;
}

class HelpResult {
  const HelpResult({required this.outcome, required this.attempt});

  /// 这次讲解的正文、来源与中断情况。
  final AnswerOutcome outcome;
  final Attempt attempt;

  /// 正文；停止或中断时是已经生成的部分。
  String get text => outcome.text;
  bool get fromModel => outcome.fromModel;
  bool get stopped => outcome.stopped;
  bool get interrupted => outcome.interrupted;

  /// 这次帮助需要界面区分的情况；提示与恢复入口都按它决定。
  List<Notice> get notices => outcome.notices;
}

/// 记录页的一屏：目标、这一页记录与每题最近一次尝试的判断。
class RecordsView {
  const RecordsView({
    required this.goals,
    required this.records,
    required this.questions,
    required this.assessments,
  });

  final List<LearningGoal> goals;
  final List<ConversationRecord> records;
  final Map<String, QuestionRow> questions;
  final Map<String, List<Assessment>> assessments;
}

/// 按本次最新的有判断的已提交尝试推出场次结果；没有提交或都没判断时留空。
///
/// 最新的答对为完成；最新的答错但本次有答对为部分完成；都有判断且都没答对
/// 为没做成。暂不判断的作答不参与推出，也不当成答错。
SessionOutcome? deriveSessionOutcome(Iterable<Attempt> attempts) {
  final submitted =
      attempts
          .where((attempt) => attempt.submitted && attempt.isCorrect != null)
          .toList()
        ..sort((a, b) => b.id.compareTo(a.id));
  if (submitted.isEmpty) return null;
  if (submitted.first.isCorrect == true) return SessionOutcome.done;
  return submitted.any((attempt) => attempt.isCorrect == true)
      ? SessionOutcome.partial
      : SessionOutcome.notDone;
}

/// 取本次最新写下的困难，作为场次摘要。
String? deriveSessionSummary(Iterable<Attempt> attempts) {
  final submitted = attempts.where((attempt) => attempt.submitted).toList()
    ..sort((a, b) => b.id.compareTo(a.id));
  for (final attempt in submitted) {
    final text = attempt.feedback?.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

/// 题目与尝试的主流程：带入、求助、提交与结束场次。
class LearningService {
  LearningService({
    required this.attempts,
    required this.conversations,
    required this.study,
    required this.memories,
    required this.revisions,
    required this.schedule,
    required this.tasks,
    required this.assessments,
    required this.ai,
    required this.context,
    required this.memoryScope,
    required this.runtime,
    required this.transactions,
  });

  final AttemptRepository attempts;
  final ConversationRepository conversations;
  final StudyRepository study;
  final MemoryRepository memories;

  /// 记忆建议写入后是否仍可撤销，由提交历史判断。
  final RevisionService revisions;
  final ScheduleRepository schedule;
  final TaskRepository tasks;
  final AssessmentRepository assessments;
  final BuddyAi ai;
  final ContextService context;

  /// 作答求助的记忆范围：记录归属优先，没有时沿用最近一次学习的目标。
  final MemoryScopeService memoryScope;
  final ServiceRuntime runtime;
  final WriteTransactions transactions;

  Future<QuestionView> view(String conversationId) async {
    final (question, recordAttempts, recent) = await (
      conversations.question(conversationId),
      attempts.attemptsFor(conversationId),
      conversations.recent(conversationId, limit: _recentMessageCount),
    ).wait;
    if (question == null) throw StateError('未找到这道题');
    final open = recordAttempts.where((attempt) => attempt.isOpen).firstOrNull;
    return QuestionView(
      question: question,
      attempts: recordAttempts,
      openAttempt: open,
      recentMessages: recent,
    );
  }

  /// 学习页在题目下方显示的消息条数。
  static const int _recentMessageCount = 6;

  /// 学习页读到的表：任一表写入之后整屏重读一次（ADR-0014）。
  ///
  /// 题目视图里的出处与材料标题来自 `material`，材料改名之后也要重读；判断与
  /// 记忆建议分别来自 `assessment` 与 `attempt`，接受记忆卡片时写入的 `memory`
  /// 一并列上，避免漏掉只写记忆的那一次提交。
  static const Set<String> _questionTables = {
    'conversation',
    'message',
    'attempt',
    'assessment',
    'material',
    'memory',
  };

  /// 跟随写入更新的学习页一屏：原题、历次尝试、最近消息、判断与记忆建议。
  Stream<QuestionView> watchQuestion(String conversationId) => runtime.watch(
    tables: _questionTables,
    read: () => loadQuestion(conversationId),
  );

  /// 读一次学习页一屏：题目、尝试与最近消息取 [view]，再补判断与记忆建议。
  Future<QuestionView> loadQuestion(String conversationId) async {
    final data = await view(conversationId);
    final open = data.openAttempt;
    final (assessments, memoryItems) = await (
      assessmentsFor(data.attempts),
      open == null
          ? Future<List<MemoryItemView>>.value(const <MemoryItemView>[])
          : memoryItemsFor(open),
    ).wait;
    return QuestionView(
      question: data.question,
      attempts: data.attempts,
      openAttempt: open,
      recentMessages: data.recentMessages,
      assessments: assessments,
      memoryItems: memoryItems,
    );
  }

  /// 有作答的记录，附带每条最近一次作答；记录页与记忆建议页共用这一份读取。
  Future<List<QuestionRow>> questionRows({
    int? limit,
    Iterable<String>? conversationIds,
  }) => conversations.questionRows(
    limit: limit,
    conversationIds: conversationIds,
  );

  /// 记录页读到的一屏：目标、这一页记录，以及每题最近一次尝试的判断。
  ///
  /// 一次读取取回整屏，订阅之后由数据层在这几张表被写入时整屏重读
  /// （ADR-0014）；分页仍按屏幕上的“继续读取”逐页追加。
  static const Set<String> _recordsTables = {
    'conversation',
    'message',
    'attempt',
    'assessment',
    'learning_goal',
    'material',
    'study_session',
  };

  /// 跟随写入更新的记录一屏；筛选与分页条件都进读取闭包。
  Stream<RecordsView> watchRecords({
    String? goalId,
    bool unassignedOnly = false,
    String? answerStatus,
    int limit = 30,
  }) => runtime.watch(
    tables: _recordsTables,
    read: () => recordsView(
      goalId: goalId,
      unassignedOnly: unassignedOnly,
      answerStatus: answerStatus,
      limit: limit,
    ),
  );

  /// 读一屏记录：目标列表与这一页记录同时发出，再补每题的判断。
  Future<RecordsView> recordsView({
    String? goalId,
    bool unassignedOnly = false,
    String? answerStatus,
    int limit = 30,
    int offset = 0,
  }) async {
    final (goals, records) = await (
      tasks.goals(),
      conversations.list(
        goalId: unassignedOnly ? null : goalId,
        unassignedOnly: unassignedOnly,
        answerStatus: answerStatus,
        limit: limit,
        offset: offset,
      ),
    ).wait;
    final questions = records.isEmpty
        ? const <QuestionRow>[]
        : await questionRows(
            conversationIds: records.map((record) => record.id),
          );
    final lastAttempts = [
      for (final row in questions)
        if (row.lastAttempt != null) row.lastAttempt!,
    ];
    final assessments = lastAttempts.isEmpty
        ? const <String, List<Assessment>>{}
        : await assessmentsFor(lastAttempts);
    return RecordsView(
      goals: goals,
      records: records,
      questions: {for (final row in questions) row.question.id: row},
      assessments: assessments,
    );
  }

  Future<String> capture({
    required String stem,
    String? sourceRef,
    String? contextText,
    List<String> imagePaths = const [],
    String? planItemId,
  }) async {
    final images = imagePaths
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
    final text = stem.trim();
    if (text.isEmpty && images.isEmpty) throw ArgumentError('题目不能为空');
    // 记录、原题消息、场次与草稿属于同一次“带入题目”，整组写入或整组回滚；
    // 同时到达的两次带入只会留下一条未提交草稿。
    return transactions.run((txn) async {
      final item = planItemId == null
          ? null
          : await tasks.byId(planItemId, transaction: txn);
      final conversationId = await conversations.create(
        entryKind: text.isEmpty
            ? EntryKind.photo
            : (images.isEmpty ? EntryKind.text : EntryKind.textPhoto),
        goalId: item?.goalId,
        sourceRef: sourceRef,
        contextText: contextText,
        transaction: txn,
      );
      if (item != null) {
        await tasks.bindConversation(item.id, conversationId, transaction: txn);
      }
      await conversations.append(
        conversationId,
        role: MessageRole.user,
        content: text,
        imagePaths: images,
        transaction: txn,
      );
      final message = await conversations.lastUserMessage(conversationId);
      if (message == null) throw StateError('题目消息没有写入');
      await conversations.setQuestionMessage(
        conversationId,
        message.id,
        transaction: txn,
      );
      final session = await _ensureSession(
        conversationId: conversationId,
        planItemId: planItemId,
        transaction: txn,
      );
      await attempts.ensureOpenAttempt(
        conversationId,
        sessionId: session.id,
        transaction: txn,
      );
      return conversationId;
    }, label: '带入题目');
  }

  /// 从一条已有讨论开始作答：题干与图片就是那时最后一条用户消息，
  /// 作答直接挂在这条记录上，不再复制题目或帮助。
  Future<String> startAnswering({required String conversationId}) async {
    final requestEpoch = runtime.dataEpoch;
    final record = await conversations.byId(conversationId);
    if (record == null) throw StateError('未找到这条讨论');
    final message = await conversations.lastUserMessage(conversationId);
    final question = await conversations.question(conversationId);
    if (question == null ||
        (question.stem.trim().isEmpty && question.imagePaths.isEmpty)) {
      throw StateError('这条讨论还没有可以作答的题目内容');
    }
    await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      if (message != null) {
        await conversations.setQuestionMessage(
          conversationId,
          message.id,
          transaction: txn,
        );
      }
      final session = await _ensureSession(
        conversationId: conversationId,
        goalId: record.goalId,
        transaction: txn,
      );
      await attempts.ensureOpenAttempt(
        conversationId,
        sessionId: session.id,
        transaction: txn,
      );
    }, label: '开始作答');
    return conversationId;
  }

  Future<HelpResult> help({
    required String questionId,
    required BuddyMode mode,
    Set<String> broughtIdentities = const {},
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    bool independentRedo = false,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    final question = await conversations.question(questionId);
    if (question == null) throw StateError('未找到这道题');
    final conversation = await conversations.byId(questionId);
    final resolved = await memoryScope.resolve(
      questionId,
      record: conversation,
    );
    final goalId = resolved.goalId;
    final storedAttempt = await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      final session = await _ensureSession(
        conversationId: questionId,
        goalId: goalId,
        transaction: txn,
      );
      return attempts.ensureOpenAttempt(
        questionId,
        sessionId: session.id,
        transaction: txn,
      );
    }, label: '准备这次求助');
    // 讨论里已经给过的回答直接作为这次求助的帮助带入，不复制进作答记录；
    // 用户选择先不看上次独立重做时，讨论回答与以前的困难都不进入这次上下文。
    final helps = <HelpEntry>[...storedAttempt.helps];
    final known = {for (final help in helps) help.content};
    if (!independentRedo) {
      final messages = await conversations.recent(questionId, limit: null);
      for (final message in messages) {
        if (message.role != MessageRole.assistant) continue;
        final text = message.content.trim();
        if (text.isEmpty || !known.add(text)) continue;
        helps.add(
          HelpEntry(
            kind: 'discuss',
            content: text,
            at: message.createdAt ?? runtime.policy.now,
          ),
        );
      }
    }
    final attempt = helps.length == storedAttempt.helps.length
        ? storedAttempt
        : Attempt(
            id: storedAttempt.id,
            conversationId: storedAttempt.conversationId,
            sessionId: storedAttempt.sessionId,
            redoOfAttemptId: storedAttempt.redoOfAttemptId,
            userAnswer: storedAttempt.userAnswer,
            solution: storedAttempt.solution,
            isCorrect: storedAttempt.isCorrect,
            independent: storedAttempt.independent,
            helps: helps,
            feedback: storedAttempt.feedback,
            delayed: storedAttempt.delayed,
            submittedAt: storedAttempt.submittedAt,
            createdAt: storedAttempt.createdAt,
          );
    final facts = await context.load(
      ContextRequest(
        question: question,
        attempt: attempt,
        assessmentRecords: await assessments.forAttempt(storedAttempt.id),
        mode: mode,
        goalId: goalId,
        materialId: conversation?.materialId,
        pageNo: conversation?.pageNo,
        conversationId: questionId,
        query: question.stem,
        broughtIdentities: broughtIdentities,
        // 上一次求助读到的材料页按当前位置接续：重试这次求助不必重新补搜。
        reusedPageKeys: reusedPageKeysOf(
          storedAttempt.helps.isEmpty
              ? const <ChatUsedPage>[]
              : storedAttempt.helps.last.usedPages,
        ),
        includeEarlier: !independentRedo,
      ),
    );
    final prompt = modePrompt(mode);

    var text = '';
    var fromModel = false;
    var stopped = false;
    var interrupted = false;

    final run = await askBuddyModel(
      ai: ai,
      filesDir: () => runtime.filesDir,
      context: facts,
      history: const [],
      prompt: prompt,
      text: question.stem,
      imagePaths: question.imagePaths,
      onPartial: onText,
      cancelToken: cancelToken,
      recordFailure: runtime.recordFailure,
    );
    _ensureCurrentEpoch(requestEpoch);
    var notices = run.notices;
    String? detail;
    final answer = run.answer;
    if (answer != null) {
      final outcome = interpretModelAnswer(
        answer,
        notices: notices,
        omittedImages: run.omittedImages,
        failure: run.failure,
        quotaReason: run.quotaReason,
        localFallback: () =>
            localBuddyReply(facts, hasImages: question.hasImages),
      );
      text = outcome.text;
      fromModel = outcome.fromModel;
      stopped = outcome.stopped;
      interrupted = outcome.interrupted;
      notices = outcome.notices;
      detail = outcome.detail;
      // 没有正文就停下时不记一条空的帮助；提示条已经说明已停止。
      if (stopped && !fromModel) text = '';
    } else {
      text = localBuddyReply(facts, hasImages: question.hasImages);
    }

    if (text.trim().isNotEmpty) {
      // 记住的意思要用户点“记下”才落库；建议随帮助保存，离开页面再回来仍在。
      final suggestions = <MemoryDraft>[];
      final modelAnswer = answer;
      if (modelAnswer != null &&
          !modelAnswer.stopped &&
          !modelAnswer.interrupted &&
          !modelAnswer.truncated) {
        final drafts = uniqueById(
          modelAnswer.memories,
          (draft) => draft.contentId,
        );
        for (final (index, draft) in drafts.indexed) {
          final content = draft.content.trim();
          if (content.isEmpty) continue;
          suggestions.add(
            MemoryDraft(
              id: 'm$index',
              kind: draft.kind,
              content: content,
              validUntil: draft.validUntil,
            ),
          );
        }
      }
      await transactions.run((txn) async {
        _ensureCurrentEpoch(requestEpoch);
        await attempts.appendHelp(
          storedAttempt.id,
          HelpEntry(
            kind: mode.value,
            content: text,
            at: runtime.policy.now,
            memories: suggestions,
            fromModel: fromModel,
            notices: notices,
            failureName: run.failure?.name,
            quotaReason: run.quotaReason?.name,
            usedPages: answer == null
                ? const <ChatUsedPage>[]
                : usedPagesOf(
                    facts,
                    answer.providedSources,
                    currentPage: facts.materialPage?.pageKey,
                  ),
          ),
          transaction: txn,
        );
      }, label: '保存讲解');
    }
    final updated = await attempts.attemptById(attempt.id);
    return HelpResult(
      outcome: AnswerOutcome(
        text: text,
        fromModel: fromModel,
        stopped: stopped,
        interrupted: interrupted,
        modelFailed: false,
        notices: notices,
        detail: detail,
        omittedImages: run.omittedImages,
        failure: run.failure,
        quotaReason: run.quotaReason,
      ),
      attempt: updated ?? attempt,
    );
  }

  /// 一条未提交尝试上的记忆建议：已写入的只保留仍可撤销的那几条。
  Future<List<MemoryItemView>> memoryItemsFor(Attempt attempt) async {
    final stored = <({int helpIndex, MemoryDraft item})>[];
    for (var index = 0; index < attempt.helps.length; index++) {
      for (final item in attempt.helps[index].memories) {
        if (item.status == MemoryCardStatus.dismissed) continue;
        stored.add((helpIndex: index, item: item));
      }
    }
    if (stored.isEmpty) return const [];
    final commitIds = <int>{
      for (final entry in stored)
        if (entry.item.status == MemoryCardStatus.accepted &&
            entry.item.commitId != null)
          entry.item.commitId!,
    };
    final active = commitIds.isEmpty
        ? const <int>{}
        : await revisions.activeCommits(commitIds);
    return [
      for (final entry in stored)
        if (entry.item.status != MemoryCardStatus.accepted ||
            (entry.item.commitId != null &&
                active.contains(entry.item.commitId)))
          MemoryItemView.help(helpIndex: entry.helpIndex, draft: entry.item),
    ];
  }

  /// 用户点“记下”后才写入帮助里的记忆建议；重复或过长时不写，卡片随之收起。
  Future<AcceptedMemory> acceptMemory({
    required String attemptId,
    required int helpIndex,
    required String itemId,
    String? uid,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    final attempt = await attempts.attemptById(attemptId);
    if (attempt == null) throw StateError('未找到这次作答');
    final item = _helpMemory(attempt, helpIndex, itemId);
    if (item == null) throw StateError('未找到这条记忆');
    if (item.status == MemoryCardStatus.accepted) {
      // 同一张卡连点两次：上一次已经写入，按重试返回，不再形成提交。
      return const AcceptedMemory(applied: true, notice: '这条记忆已经处理。');
    }
    if (item.status != MemoryCardStatus.pending) {
      throw StateError('这条记忆已经处理');
    }
    final scope = (await memoryScope.resolve(attempt.conversationId)).scope;
    try {
      return await transactions.run(
        (txn) async {
          _ensureCurrentEpoch(requestEpoch);
          return confirmMemoryDraft(
            transaction: txn,
            transactions: transactions,
            memories: memories,
            draft: item,
            sourceKind: MemorySourceKind.attempt,
            sourceId: attemptId,
            scope: scope,
            clock: runtime.policy.clock,
            recordStatus: (status, commitId) => _setHelpMemoryStatus(
              attemptId,
              helpIndex,
              itemId,
              status: status,
              commitId: commitId,
              transaction: txn,
            ),
          );
        },
        label: confirmAttemptMemoryAction,
        uid: uid ?? newUuidV7(),
      );
    } on RevisionDuplicateRequest {
      // 同一次确认已经写入；重试按库里的状态返回，不再重复写记忆。
      final refreshed = await attempts.attemptById(attemptId);
      final current = refreshed == null
          ? null
          : _helpMemory(refreshed, helpIndex, itemId);
      return AcceptedMemory(
        applied: current?.status == MemoryCardStatus.accepted,
        notice: '这条记忆已经处理。',
      );
    }
  }

  /// 用户点“不记”后收起建议；没有写入记忆，不需要撤销。
  Future<void> dismissMemory({
    required String attemptId,
    required int helpIndex,
    required String itemId,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    final attempt = await attempts.attemptById(attemptId);
    if (attempt == null) throw StateError('未找到这次作答');
    final item = _helpMemory(attempt, helpIndex, itemId);
    if (item == null) throw StateError('未找到这条记忆');
    if (item.status != MemoryCardStatus.pending) {
      throw StateError('这条记忆已经处理');
    }
    await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      await _setHelpMemoryStatus(
        attemptId,
        helpIndex,
        itemId,
        status: MemoryCardStatus.dismissed,
        transaction: txn,
      );
    }, label: '收起作答记忆');
  }

  static MemoryDraft? _helpMemory(
    Attempt attempt,
    int helpIndex,
    String itemId,
  ) {
    if (helpIndex < 0 || helpIndex >= attempt.helps.length) return null;
    for (final item in attempt.helps[helpIndex].memories) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  Future<void> _setHelpMemoryStatus(
    String attemptId,
    int helpIndex,
    String itemId, {
    required MemoryCardStatus status,
    int? commitId,
    WriteTransaction? transaction,
  }) async {
    await attempts.updateHelp(
      attemptId,
      helpIndex,
      (help) => help.withMemories([
        for (final memory in help.memories)
          if (memory.id == itemId)
            memory.copyWith(
              status: status,
              commitId: commitId,
              clearCommitId: commitId == null,
            )
          else
            memory,
      ]),
      transaction: transaction,
    );
  }

  /// 提交一次作答；对错与独立性都可以留空，表示暂不判断或未说明。
  ///
  /// 自评不再单独写一条判断，作答记录里的帮助次数、独立与延迟情况已经足够
  /// 推出结果；用户填写的核对依据单独保存，只表示用户提供了一个依据。
  Future<WriteResult> submit({
    required String attemptId,
    required String answer,
    String? solution,
    required bool? isCorrect,
    required bool? independent,
    bool delayed = false,
    String? feedback,
    String? checkable,
    String? uid,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    return transactions.run(
      (txn) async {
        _ensureCurrentEpoch(requestEpoch);
        final before = await attempts.attemptById(attemptId, transaction: txn);
        if (before == null) throw StateError('未找到这次作答');
        if (before.submitted) {
          throw StateError('这次作答已经提交，请新建一次作答');
        }
        await assessments.saveUserBasisDraft(
          attemptId,
          checkable,
          transaction: txn,
        );
        final changed = await attempts.submit(
          attemptId,
          answer: answer,
          solution: solution,
          isCorrect: isCorrect,
          independent: independent,
          delayed: delayed,
          feedback: feedback,
          transaction: txn,
        );
        if (changed != 1) throw StateError('这次作答已提交，请新建一次作答');
        return txn.result();
      },
      label: '提交作答',
      uid: uid,
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  Future<Map<String, List<Assessment>>> assessmentsFor(List<Attempt> attempts) {
    return assessments.forAttempts([
      for (final attempt in attempts) attempt.id,
    ]);
  }

  /// 让模型检查这次作答的依据；判断只保存来源、结论与依据，不标记是否核对。
  Future<Assessment> assessWithModel({
    required String questionId,
    required String attemptId,
    Set<String> broughtIdentities = const {},
    String? uid,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    final question = await conversations.question(questionId);
    if (question == null) throw StateError('未找到这道题');
    final conversation = await conversations.byId(questionId);
    final attempt = await attempts.attemptById(attemptId);
    if (attempt == null) throw StateError('未找到这次作答');
    if (attempt.conversationId != questionId) {
      throw ArgumentError('这次作答不属于当前题目');
    }
    final goalId = conversation?.goalId;
    final facts = await context.load(
      ContextRequest(
        question: question,
        attempt: attempt,
        assessmentRecords: await assessments.forAttempt(attemptId),
        mode: BuddyMode.check,
        goalId: goalId,
        materialId: conversation?.materialId,
        pageNo: conversation?.pageNo,
        conversationId: questionId,
        query: question.stem,
        broughtIdentities: broughtIdentities,
      ),
    );
    final config = (await ai.config()).valueOrNull;
    final prepared = await AttachmentService(filesDir: () => runtime.filesDir)
        .prepare(question.imagePaths, enabled: config?.allowImages ?? false);
    if (question.stem.trim().isEmpty && prepared.images.isEmpty) {
      throw StateError(
        prepared.omitted.isEmpty
            ? '没有可发送的题目图片，无法进行模型判断。'
            : '题目图片都没有发送'
                  '（${prepared.omitted.map((reason) => reason.name).join('、')}），'
                  '无法进行模型判断。',
      );
    }
    final answer = await ai.ask(
      context: facts,
      history: const [],
      text:
          '检查这次作答的依据：先逐项复述作答记录里的自评、独立性、'
          '延迟情况、应用内帮助、应用外帮助与用户提供的核对依据，再判断证据是否支持；'
          '没有实际证据的部分必须标为待核实，不得补造。',
      images: prepared.images,
      configSnapshot: LlmConfigSnapshot(config),
    );
    // 等待模型期间可能发生了整库恢复或版本恢复；迟到的判断不再写回新数据。
    _ensureCurrentEpoch(requestEpoch);
    final draft = answer.assessment;
    if (draft == null) {
      throw StateError('模型未提供可用判断');
    }
    late final String id;
    try {
      id = await transactions.run(
        (txn) async {
          _ensureCurrentEpoch(requestEpoch);
          return assessments.add(
            attemptId: attemptId,
            kind: AssessmentKind.model,
            result: draft.result,
            basis: draft.basis ?? '模型未提供具体依据',
            transaction: txn,
          );
        },
        label: '保存模型判断',
        uid: uid,
      );
    } on RevisionDuplicateRequest {
      // 同一次判断已经写入；重试读回原结果，不再新增一条。
      final stored = await assessments.latestOfKind(
        attemptId,
        AssessmentKind.model,
      );
      if (stored != null) return stored;
      rethrow;
    }
    final stored = await assessments.latestOfKind(
      attemptId,
      AssessmentKind.model,
    );
    return stored ??
        Assessment(
          id: id,
          attemptId: attemptId,
          kind: AssessmentKind.model,
          result: draft.result,
          basis: draft.basis,
        );
  }

  /// 取一条新的未提交尝试，用于同一条记录的再次作答。
  ///
  /// [independentRedo] 为真时把新尝试关联到最近一次已提交作答，重做状态随
  /// 尝试保存，重新打开页面仍能回到“先不看上次”的模式。
  Future<Attempt> openAttempt(
    String conversationId, {
    bool independentRedo = false,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    final conversation = await conversations.byId(conversationId);
    final previous = independentRedo
        ? await attempts.latestSubmitted(conversationId)
        : null;
    final redoOf = previous?.id;
    final delayed =
        previous?.submittedAt != null &&
        runtime.policy.now.difference(previous!.submittedAt!) >=
            const Duration(hours: 12);
    return transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      final session = await _ensureSession(
        conversationId: conversationId,
        goalId: conversation?.goalId,
        transaction: txn,
      );
      return attempts.ensureOpenAttempt(
        conversationId,
        sessionId: session.id,
        redoOfAttemptId: redoOf,
        delayed: delayed,
        transaction: txn,
      );
    }, label: '开始作答');
  }

  /// 保存整份作答草稿：答案、自评、依据与核对依据一起留下。
  ///
  /// 未提交时点检查、保存草稿或离开学习页都走这里；核对依据写到判断表，
  /// 提交时沿用同一条，不再重复新增。
  Future<void> saveDraft({
    required String attemptId,
    required String answer,
    String? solution,
    bool? isCorrect,
    bool? independent,
    bool delayed = false,
    String? feedback,
    String? checkable,
    String? uid,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    await transactions.run(
      (txn) async {
        _ensureCurrentEpoch(requestEpoch);
        final before = await attempts.attemptById(attemptId, transaction: txn);
        if (before == null) throw StateError('未找到这次作答');
        if (before.submitted) {
          throw StateError('这次作答已经提交，草稿不能再修改');
        }
        await attempts.saveDraft(
          attemptId,
          answer: answer,
          solution: solution,
          isCorrect: isCorrect,
          independent: independent,
          delayed: delayed,
          feedback: feedback,
          transaction: txn,
        );
        await assessments.saveUserBasisDraft(
          attemptId,
          checkable,
          transaction: txn,
        );
      },
      label: '保存作答草稿',
      uid: uid,
      onDuplicate: (_) {},
    );
  }

  /// 离开学习页时结束本次场次，结果由本次已提交的尝试推出。
  ///
  /// 场次只作为后台记录：最近一次答对记为完成，答错但本次有答对记为部分完成，
  /// 其余记为没做成；没有提交过时结果留空。困难留在这条记录与作答记录里，
  /// 不另写记忆：场次摘要与作答都还在，模型可以在讨论里用新增写一条情景记忆
  /// 并指向场次编号（ADR-0051 决定第 4 条）。
  Future<void> closeForQuestion(String conversationId) async {
    final recordAttempts = await attempts.attemptsFor(conversationId);
    final sessionId = recordAttempts.firstOrNull?.sessionId;
    if (sessionId == null) return;
    final session = await study.byId(sessionId);
    if (session == null || session.endedAt != null) return;
    final scoped = recordAttempts
        .where((attempt) => attempt.sessionId == session.id)
        .toList(growable: false);
    await end(
      session: session,
      outcome: deriveSessionOutcome(scoped),
      summary: deriveSessionSummary(scoped),
    );
  }

  /// 结束一次场次：写结果与一句困难；事项状态由事项自己的完成操作维护。
  ///
  /// 困难留在作答记录与场次摘要里，不再按“同一困难反复出现”自动写成记忆：
  /// 那条规则是推断且不出确认卡片，用户删掉的困难也会被同样的摘要写回，
  /// 所以随 ADR-0051 决定第 4 条删除。
  Future<WriteResult> end({
    required StudySession session,
    SessionOutcome? outcome,
    String? summary,
  }) async {
    final requestEpoch = runtime.dataEpoch;
    return transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      await study.end(
        session.id,
        outcome: outcome,
        summary: summary,
        transaction: txn,
      );
      return txn.result();
    }, label: '结束学习');
  }

  Future<StudySession> _ensureSession({
    required String conversationId,
    String? planItemId,
    String? goalId,
    WriteTransaction? transaction,
  }) async {
    final item = planItemId == null
        ? await tasks.byConversation(conversationId)
        : await tasks.byId(planItemId, transaction: transaction);
    final resolvedPlanItemId = planItemId ?? item?.id;
    final resolvedGoalId = goalId ?? item?.goalId;
    var open = await study.openFor(
      conversationId: conversationId,
      planItemId: resolvedPlanItemId,
      goalId: resolvedGoalId,
      transaction: transaction,
    );
    // 同一条记录换了目标或步骤：先结束上一段，再从这次改动开始新建场次，
    // 不能让旧场次的目标继续带进新的作答。
    if (open != null &&
        (open.goalId != resolvedGoalId ||
            open.planItemId != resolvedPlanItemId)) {
      await study.end(open.id, transaction: transaction);
      open = null;
    }
    if (open != null) return open;
    return study.start(
      conversationId: conversationId,
      planItemId: resolvedPlanItemId,
      goalId: resolvedGoalId,
      transaction: transaction,
    );
  }

  void _ensureCurrentEpoch(int expected) {
    if (runtime.dataEpoch != expected) {
      throw StateError('数据已恢复或清空，请重新打开这条学习记录后再求助。');
    }
  }
}
