import '../ai/ai_chat_service.dart';
import '../ai/llm_client.dart';
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
import '../domain/models/memory.dart';
import '../domain/models/question.dart';
import '../domain/models/study.dart';
import '../domain/rules/content_identity.dart';
import 'buddy_fallback.dart';
import '../domain/rules/time_policy.dart';
import 'buddy_actions.dart';
import 'buddy_answer.dart';
import 'attachment_service.dart';
import 'context_service.dart';
import 'memory_scope_service.dart';
import 'reply_outcome.dart';

/// 一道题的当前状态：原题、尝试与一条未提交尝试。
class QuestionView {
  const QuestionView({
    required this.question,
    required this.attempts,
    this.openAttempt,
  });

  final Question question;
  final List<Attempt> attempts;
  final Attempt? openAttempt;

  Attempt? get lastSubmitted => attempts
      .where((attempt) => attempt.submitted)
      .cast<Attempt?>()
      .firstWhere((attempt) => true, orElse: () => null);
}

class HelpResult {
  const HelpResult({
    required this.text,
    required this.attempt,
    this.fromModel = false,
    this.stopped = false,
    this.interrupted = false,
    this.notice,
    this.changes = const [],
  });

  final String text;
  final Attempt attempt;
  final bool fromModel;

  /// 用户在生成中停止；[text] 是停下时已经显示的部分。
  final bool stopped;

  /// 生成中断；[text] 是中断前已经显示的部分。
  final bool interrupted;
  final String? notice;
  final List<AppliedChange> changes;
}

/// 一条帮助里的记忆建议：待确认、已写入或已收起。
class HelpMemoryView {
  const HelpMemoryView({
    required this.helpIndex,
    required this.itemId,
    required this.draft,
    required this.status,
    this.commitId,
  });

  final int helpIndex;
  final String itemId;
  final MemoryDraft draft;
  final String status;
  final int? commitId;

  bool get pending => status == 'pending';
  bool get applied => status == 'accepted';
}

/// 用户点“记下”后的结果；重复或过长时没有写入。
class AcceptedHelpMemory {
  const AcceptedHelpMemory({required this.applied, this.change, this.notice});

  final bool applied;
  final AppliedChange? change;
  final String? notice;
}

/// 按本次最新的有判断的已提交尝试推出场次结果；没有提交或都没判断时留空。
///
/// 最新的答对为完成；最新的答错但本次有答对为部分完成；都有判断且都没答对
/// 为没做成。暂不判断的作答不参与推出，也不当成答错。
String? deriveSessionOutcome(Iterable<Attempt> attempts) {
  final submitted =
      attempts
          .where((attempt) => attempt.submitted && attempt.isCorrect != null)
          .toList()
        ..sort((a, b) => b.id.compareTo(a.id));
  if (submitted.isEmpty) return null;
  if (submitted.first.isCorrect == true) return 'done';
  return submitted.any((attempt) => attempt.isCorrect == true)
      ? 'partial'
      : 'not_done';
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
    required this.policy,
    required this.transactions,
    required this.filesDir,
    int Function()? dataEpoch,
    this.recordFailure,
  }) : dataEpoch = dataEpoch ?? _zeroDataEpoch;

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
  final TimePolicy Function() policy;
  final WriteTransactions transactions;
  final String Function() filesDir;
  final int Function() dataEpoch;

  /// 模型调用的类型、消息与调用栈只交给本机诊断记录，不进入界面说明。
  final ModelFailureRecorder? recordFailure;

  Future<QuestionView> view(int conversationId) async {
    final question = await conversations.question(conversationId);
    if (question == null) throw StateError('未找到这道题');
    final recordAttempts = await attempts.attemptsFor(conversationId);
    final open = recordAttempts.where((attempt) => attempt.isOpen).firstOrNull;
    return QuestionView(
      question: question,
      attempts: recordAttempts,
      openAttempt: open,
    );
  }

  Future<int> capture({
    required String stem,
    String? sourceRef,
    String? contextText,
    List<String> imagePaths = const [],
    int? planItemId,
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
            ? 'photo'
            : (images.isEmpty ? 'text' : 'text_photo'),
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
        role: 'user',
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
  Future<int> startAnswering({required int conversationId}) async {
    final requestEpoch = dataEpoch();
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
    required int questionId,
    required BuddyMode mode,
    Set<String> broughtIdentities = const {},
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    bool independentRedo = false,
  }) async {
    final requestEpoch = dataEpoch();
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
        if (message.role != 'assistant') continue;
        final text = message.content.trim();
        if (text.isEmpty || !known.add(text)) continue;
        helps.add(
          HelpEntry(
            kind: 'discuss',
            content: text,
            at: message.createdAt ?? policy().now,
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
      includeEarlier: !independentRedo,
    );
    final prompt = switch (mode) {
      BuddyMode.hint => '给我一个提示，不直接给答案。',
      BuddyMode.explain => '完整讲这道题，讲清依据。',
      BuddyMode.check => '检查我的做法，指出第一个需要改的地方。',
      BuddyMode.chat => '看看这道题，告诉我现在最该做的一步。',
      BuddyMode.plan => '按材料范围提出学习顺序。',
    };

    var text = '';
    var fromModel = false;
    var stopped = false;
    var interrupted = false;
    const changes = <AppliedChange>[];

    final run = await askBuddyModel(
      ai: ai,
      filesDir: filesDir,
      context: facts,
      history: const [],
      prompt: prompt,
      text: question.stem,
      imagePaths: question.imagePaths,
      onPartial: onText,
      cancelToken: cancelToken,
      recordFailure: recordFailure,
    );
    _ensureCurrentEpoch(requestEpoch);
    var notice = run.notice;
    final answer = run.answer;
    if (answer != null) {
      final outcome = interpretModelAnswer(
        answer,
        notice: notice,
        localFallback: () => localBuddyReply(
          facts,
          modelMissing: false,
          hasImages: question.hasImages,
        ),
        fallbackNotice: modelFallbackNotice,
      );
      text = outcome.text;
      fromModel = outcome.fromModel;
      stopped = outcome.stopped;
      interrupted = outcome.interrupted;
      notice = outcome.notice;
      // 没有正文就停下时不记一条空的帮助；提示条已经说明已停止。
      if (stopped && !fromModel) text = '';
    } else {
      text = localBuddyReply(
        facts,
        modelMissing: run.modelMissing,
        hasImages: question.hasImages,
      );
    }

    if (text.trim().isNotEmpty) {
      // 记住的意思要用户点“记下”才落库；建议随帮助保存，离开页面再回来仍在。
      final suggestions = <HelpMemory>[];
      final modelAnswer = answer;
      if (modelAnswer != null &&
          !modelAnswer.stopped &&
          !modelAnswer.interrupted) {
        final drafts = uniqueById(
          modelAnswer.memories,
          (draft) => draft.contentId,
        );
        for (final (index, draft) in drafts.indexed) {
          final content = draft.content.trim();
          if (content.isEmpty) continue;
          suggestions.add(
            HelpMemory(
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
            at: policy().now,
            memories: suggestions,
          ),
          transaction: txn,
        );
      }, label: '保存讲解');
    }
    final updated = await attempts.attemptById(attempt.id);
    return HelpResult(
      text: text,
      attempt: updated ?? attempt,
      fromModel: fromModel,
      stopped: stopped,
      interrupted: interrupted,
      notice: notice,
      changes: changes,
    );
  }

  /// 一条未提交尝试上的记忆建议：已写入的只保留仍可撤销的那几条。
  Future<List<HelpMemoryView>> memoryItemsFor(Attempt attempt) async {
    final stored = <({int helpIndex, HelpMemory item})>[];
    for (var index = 0; index < attempt.helps.length; index++) {
      for (final item in attempt.helps[index].memories) {
        if (item.status == 'dismissed') continue;
        stored.add((helpIndex: index, item: item));
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
    return [
      for (final entry in stored)
        if (entry.item.status != 'accepted' ||
            (entry.item.commitId != null &&
                active.contains(entry.item.commitId)))
          HelpMemoryView(
            helpIndex: entry.helpIndex,
            itemId: entry.item.id,
            draft: MemoryDraft(
              kind: entry.item.kind,
              content: entry.item.content,
              validUntil: entry.item.validUntil,
              source: MemorySource.inferred,
            ),
            status: entry.item.status,
            commitId: entry.item.commitId,
          ),
    ];
  }

  /// 用户点“记下”后才写入帮助里的记忆建议；重复或过长时不写，卡片随之收起。
  Future<AcceptedHelpMemory> acceptMemory({
    required int attemptId,
    required int helpIndex,
    required String itemId,
    String? requestId,
  }) async {
    final requestEpoch = dataEpoch();
    final attempt = await attempts.attemptById(attemptId);
    if (attempt == null) throw StateError('未找到这次作答');
    final item = _helpMemory(attempt, helpIndex, itemId);
    if (item == null) throw StateError('未找到这条记忆');
    if (item.status != 'pending') throw StateError('这条记忆已经处理');
    final scope = (await memoryScope.resolve(attempt.conversationId)).scope;
    try {
      return await transactions.run(
        (txn) async {
          _ensureCurrentEpoch(requestEpoch);
          final applied = await applyMemoryDrafts(
            transactions: transactions,
            memories: memories,
            drafts: [
              MemoryDraft(
                kind: item.kind,
                content: item.content,
                validUntil: item.validUntil,
              ),
            ],
            sourceKind: 'attempt',
            sourceId: attemptId,
            scope: scope,
            transaction: txn,
            clock: policy().clock,
          );
          if (applied.changes.isEmpty) {
            await _setHelpMemoryStatus(
              attemptId,
              helpIndex,
              itemId,
              status: 'dismissed',
              transaction: txn,
            );
            return const AcceptedHelpMemory(
              applied: false,
              notice: '这条记忆已经存在，没有重复保存。',
            );
          }
          final change = applied.changes.first;
          await _setHelpMemoryStatus(
            attemptId,
            helpIndex,
            itemId,
            status: 'accepted',
            commitId: change.commitId,
            transaction: txn,
          );
          return AcceptedHelpMemory(applied: true, change: change);
        },
        label: confirmAttemptMemoryAction,
        requestId: requestId,
      );
    } on RevisionDuplicateRequest {
      // 同一次确认已经写入；重试按库里的状态返回，不再重复写记忆。
      final refreshed = await attempts.attemptById(attemptId);
      final current = refreshed == null
          ? null
          : _helpMemory(refreshed, helpIndex, itemId);
      return AcceptedHelpMemory(
        applied: current?.status == 'accepted',
        notice: '这条记忆已经处理。',
      );
    }
  }

  /// 用户点“不记”后收起建议；没有写入记忆，不需要撤销。
  Future<void> dismissMemory({
    required int attemptId,
    required int helpIndex,
    required String itemId,
  }) async {
    final requestEpoch = dataEpoch();
    final attempt = await attempts.attemptById(attemptId);
    if (attempt == null) throw StateError('未找到这次作答');
    final item = _helpMemory(attempt, helpIndex, itemId);
    if (item == null) throw StateError('未找到这条记忆');
    if (item.status != 'pending') throw StateError('这条记忆已经处理');
    await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      await _setHelpMemoryStatus(
        attemptId,
        helpIndex,
        itemId,
        status: 'dismissed',
        transaction: txn,
      );
    }, label: '收起作答记忆');
  }

  static HelpMemory? _helpMemory(
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
    int attemptId,
    int helpIndex,
    String itemId, {
    required String status,
    int? commitId,
    WriteTransaction? transaction,
  }) async {
    await attempts.updateHelp(
      attemptId,
      helpIndex,
      (help) => help.withMemories([
        for (final memory in help.memories)
          if (memory.id == itemId)
            HelpMemory(
              id: memory.id,
              kind: memory.kind,
              content: memory.content,
              validUntil: memory.validUntil,
              status: status,
              commitId: commitId,
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
  Future<void> submit({
    required int attemptId,
    required String answer,
    String? solution,
    required bool? isCorrect,
    required bool? independent,
    bool delayed = false,
    String? feedback,
    String? checkable,
    String? requestId,
  }) async {
    final requestEpoch = dataEpoch();
    await transactions.run(
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
      },
      label: '提交作答',
      requestId: requestId,
      onDuplicate: (_) {},
    );
  }

  Future<Map<int, List<Assessment>>> assessmentsFor(List<Attempt> attempts) {
    return assessments.forAttempts([
      for (final attempt in attempts) attempt.id,
    ]);
  }

  /// 让模型检查这次作答的依据；判断只保存来源、结论与依据，不标记是否核对。
  Future<Assessment> assessWithModel({
    required int questionId,
    required int attemptId,
    Set<String> broughtIdentities = const {},
    String? requestId,
  }) async {
    final requestEpoch = dataEpoch();
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
    );
    final config = await ai.config();
    final prepared = await AttachmentService(filesDir: filesDir)
        .prepare(question.imagePaths, enabled: config?.allowImages ?? false);
    if (question.stem.trim().isEmpty && prepared.images.isEmpty) {
      throw StateError(prepared.notice ?? '没有可发送的题目图片，无法进行模型判断。');
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
    late final int id;
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
        requestId: requestId,
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
    int conversationId, {
    bool independentRedo = false,
  }) async {
    final requestEpoch = dataEpoch();
    final conversation = await conversations.byId(conversationId);
    final previous = independentRedo
        ? await attempts.latestSubmitted(conversationId)
        : null;
    final redoOf = previous?.id;
    final delayed =
        previous?.submittedAt != null &&
        policy().now.difference(previous!.submittedAt!) >=
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
    required int attemptId,
    required String answer,
    String? solution,
    bool? isCorrect,
    bool? independent,
    bool delayed = false,
    String? feedback,
    String? checkable,
    String? requestId,
  }) async {
    final requestEpoch = dataEpoch();
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
      requestId: requestId,
      onDuplicate: (_) {},
    );
  }

  /// 离开学习页时结束本次场次，结果由本次已提交的尝试推出。
  ///
  /// 场次只作为后台记录：最近一次答对记为完成，答错但本次有答对记为部分完成，
  /// 其余记为没做成；没有提交过时结果留空。困难留在这场学习与作答记录里，
  /// 不另写独立记忆，再次作答时只带入这道题以前留下的困难。
  Future<void> closeForQuestion(int conversationId) async {
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
  /// 困难同时留在作答记录的 `feedback` 里，场次只保留摘要；只有用户明确要求
  /// 记住，或同一困难在同一目标下反复出现时才写成独立记忆（00 第 4 章）。
  Future<void> end({
    required StudySession session,
    String? outcome,
    String? summary,
  }) async {
    final requestEpoch = dataEpoch();
    await transactions.run((txn) async {
      _ensureCurrentEpoch(requestEpoch);
      await study.end(
        session.id,
        outcome: outcome,
        summary: summary,
        transaction: txn,
      );
      await _promoteRepeatedDifficulty(session, summary, transaction: txn);
    }, label: '结束学习');
  }

  /// 同一目标下同一困难再次出现时，才写成独立记忆。
  ///
  /// 只比较同一目标的场次摘要，按去掉多余空白后的整句判断；同一范围内已经
  /// 有一条相同内容的困难记忆时不再重复写。场次没有目标归属时不升级。
  Future<void> _promoteRepeatedDifficulty(
    StudySession session,
    String? summary, {
    WriteTransaction? transaction,
  }) async {
    final goalId = session.goalId;
    if (goalId == null) return;
    final text = _difficultyKey(summary ?? '');
    if (text.isEmpty) return;
    final earlier = await study.recentForGoal(goalId, limit: null);
    final repeated = earlier.any(
      (other) =>
          other.id != session.id && _difficultyKey(other.summary ?? '') == text,
    );
    if (!repeated) return;
    final scope = memoryGoalScope(goalId);
    final existing = await memories.activeDifficulties(scope);
    final known = existing.any(
      (memory) => _difficultyKey(memory.content) == text,
    );
    if (known) return;
    // 超过写入长度的困难不截成半句记忆；完整内容仍留在作答记录的困难里。
    if (text.length > 200) return;
    await memories.create(
      kind: MemoryKind.difficulty,
      content: text,
      scope: scope,
      sourceKind: 'session',
      sourceId: session.id,
      transaction: transaction,
    );
  }

  String _difficultyKey(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<StudySession> _ensureSession({
    required int conversationId,
    int? planItemId,
    int? goalId,
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
    if (dataEpoch() != expected) {
      throw StateError('数据已恢复或清空，请重新打开这条学习记录后再求助。');
    }
  }
}

int _zeroDataEpoch() => 0;
