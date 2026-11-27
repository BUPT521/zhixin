import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../app_scope.dart';
import '../application/answer_outcome.dart';
import '../domain/models/buddy_protocol.dart';
import '../application/learning_service.dart';
import '../application/memory_view.dart';
import '../domain/models/assessment.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/question.dart';
import '../domain/rules/notices.dart';
import '../domain/rules/uuid_v7.dart';
import '../domain/rules/text.dart';
import 'answer_notice.dart';
import 'buddy_flows.dart';
import 'buddy_timeline.dart';
import 'discussion_message.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_segmented.dart';
import 'zhixin_toast.dart';

/// 学习中：原题、历次尝试、提示与讲解，以及这次的结果。
class LearningPage extends StatefulWidget {
  const LearningPage({
    super.key,
    required this.questionId,
    this.startRedo = false,
  });

  final String questionId;

  /// 从记录页的复查入口进入时直接进入独立重做，不再让用户先点一次。
  final bool startRedo;

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
  /// 这道题的一屏订阅：原题、历次尝试、最近消息、判断与记忆建议都从它读
  /// （ADR-0014），保存、求助、接受记忆与提交之后的重读由数据层完成。
  Stream<QuestionView>? _stream;

  QuestionView? _view;

  /// 首读失败的原因；页面据此在骨架屏位置显示说明，不再一直转圈。
  String? _readError;

  bool _busy = false;

  /// 失败说明：用错误样式，按状态带恢复入口。
  String? _failure;

  /// 一次回答的收尾说明：写明保留了什么与下一步，不画错误样式。
  String? _result;

  /// 页面引导，例如提交前提示先写答案；只说明怎么做，不表示失败。
  String? _hint;

  bool _started = false;
  bool _leaving = false;

  /// 生成中的帮助只重建结果卡片，不带着整页题目与历次尝试一起重建。
  final ValueNotifier<String> _streamingHelp = ValueNotifier<String>('');
  bool _generating = false;
  LlmCancelToken? _cancelToken;

  /// 已经展开全部帮助的尝试；默认只显示最近两条，更早的仍然可以查看。
  final Set<String> _expandedHelps = <String>{};

  /// 模型是否可用（已经登录）；求助的模式和收尾状态随帮助记录读取。
  bool _configured = false;

  /// 作答草稿留在学习页上，检查与提交都读这一份；未提交的尝试是它的保存处。
  final _answerDraft = TextEditingController();
  final _solutionDraft = TextEditingController();
  final _feedbackDraft = TextEditingController();
  final _checkableDraft = TextEditingController();
  bool? _correct;
  bool? _independent;
  bool _delayed = false;
  String? _draftAttemptId;

  /// 保存草稿、提交与模型判断各保留一个请求身份：写入失败后用户再点一次时
  /// 沿用同一个编号，数据层按提交去重，不会重复写一条草稿或多提交一次作答。
  final _draftRequest = _RequestIdentity();
  final _submitRequest = _RequestIdentity();
  final _assessRequest = _RequestIdentity();

  /// 用户选择先不看上次答案重做时，隐藏历次尝试，求助不带入旧讨论回答与困难。
  bool _independentRedo = false;

  /// 从记录页复查入口进入时，第一次读取之后自动进入独立重做。
  bool _autoRedoStarted = false;

  /// 时间线只向页面取当前帮助、记忆与回执，排列与失败说明由共用组件负责。
  late final BuddyTimelineAdapter _timelineAdapter = _LearningTimeline(this);

  /// 每次尝试的判断；订阅回填之前为空。
  Map<String, List<Assessment>> get _assessments =>
      _view?.assessments ?? const {};

  /// 当前未提交尝试上的记忆建议：待确认的可以「记下」，已写入的可以撤销。
  List<MemoryItemView> get _memoryItems =>
      _view?.memoryItems ?? const <MemoryItemView>[];

  /// 同一条记录最近几条讨论消息；学习页把讨论与作答放在一起，完整讨论另开。
  List<ChatMessage> get _recentMessages =>
      _view?.recentMessages ?? const <ChatMessage>[];

  @override
  void dispose() {
    _streamingHelp.dispose();
    _answerDraft.dispose();
    _solutionDraft.dispose();
    _feedbackDraft.dispose();
    _checkableDraft.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _stream = AppScope.of(context).chat.learning
        .watchQuestion(widget.questionId);
    _readConfigured();
  }

  /// 模型配置决定帮助下方的恢复入口；它不随这些表写入变化，只读一次。
  /// 模型只有知新服务一种来源，登录之后才算可用（ADR-0050）。
  Future<void> _readConfigured() async {
    try {
      final ready = await AppScope.of(context).modelReady();
      if (!mounted) return;
      setState(() => _configured = ready);
    } catch (_) {
      // 配置读不到时按未配置显示，不打断题目与作答本身的读取。
    }
  }

  /// 订阅回填一屏结果：换掉题目与尝试，并把草稿、独立重做状态与自动进入
  /// 复查这几件事一次处理完。
  void _onQuestion(QuestionView view) {
    _view = view;
    _readError = null;
    final open = view.openAttempt;
    // 独立重做只在存在未提交尝试时由它决定；提交之后尝试结束，页面自己复位。
    if (open != null) _independentRedo = open.redoOfAttemptId != null;
    _applyDraft(open);
    if (widget.startRedo &&
        !_autoRedoStarted &&
        open == null &&
        view.attempts.any((attempt) => attempt.submitted)) {
      _autoRedoStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startRedo();
      });
    }
  }

  /// 读取失败时保留已经显示的内容并就地说明一次；首读失败不再停在骨架屏。
  ///
  /// 有就地说明时不再另外弹一条相同的 toast；重试入口只在首读失败时给出，
  /// 重新订阅这道题之后再读到结果就收起。
  void _onQuestionError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取这道题与作答记录',
      kind: 'learning_read',
      kept: '本机记录没有改动',
      next: '可以点下面「重试」再读一次',
    );
    setState(() {
      if (_view == null) {
        _readError = message;
      } else {
        _failure = message;
      }
    });
  }

  /// 首读失败之后重新订阅这道题；已经显示的内容留到新结果到达。
  void _retryRead() {
    setState(() {
      _readError = null;
      _stream = AppScope.of(context).chat.learning
          .watchQuestion(widget.questionId);
    });
  }

  /// 把未提交的尝试读回草稿；同一条尝试上的修改不覆盖用户正在写的内容。
  void _applyDraft(Attempt? attempt, {bool force = false}) {
    final helped = attempt?.helps.isNotEmpty ?? false;
    if (!force && attempt?.id == _draftAttemptId) {
      if (helped) _independent = null;
      return;
    }
    _draftAttemptId = attempt?.id;
    final draft = _AnswerDraft.from(attempt, _checkableOf);
    _answerDraft.text = draft.answer;
    _solutionDraft.text = draft.solution;
    _feedbackDraft.text = draft.feedback;
    _checkableDraft.text = draft.checkable;
    _correct = draft.correct;
    _independent = draft.independent;
    _delayed = draft.delayed;
  }

  /// 草稿里已经填过核对依据时带回来；之后的修改直接覆盖同一条判断。
  String _checkableOf(String? attemptId) {
    if (attemptId == null) return '';
    for (final assessment
        in (_assessments[attemptId] ?? const <Assessment>[]).reversed) {
      if (assessment.kind == AssessmentKind.user) return assessment.result;
    }
    return '';
  }

  /// 页面当前这一份草稿；文本、自评与独立性只在值对象上比较一次。
  _AnswerDraft get _draft => _AnswerDraft(
    answer: _answerDraft.text,
    solution: _solutionDraft.text,
    feedback: _feedbackDraft.text,
    checkable: _checkableDraft.text,
    correct: _correct,
    independent: _independent,
    delayed: _delayed,
  );

  /// 保存整份草稿；检查、提交与离开学习页之前都先调用它。
  ///
  /// 同一次动作重试沿用同一个提交身份，换了一条尝试就换身份；身份是动作开始时
  /// 生成的一个 UUIDv7（ADR-0053 决定第 3 条）。
  Future<bool> _saveDraft({bool notify = true}) async {
    final open = _view?.openAttempt;
    final draft = _draft;
    final saved = _AnswerDraft.from(open, _checkableOf);
    if (!draft.hasContent && !saved.hasContent) {
      if (notify && mounted) {
        showToast(context, '还没有写下草稿');
      }
      return true;
    }
    if (draft == saved) {
      if (notify && mounted) {
        showToast(context, '草稿已保存，可继续补充');
      }
      return true;
    }
    final service = AppScope.of(context).chat.learning;
    try {
      final attempt = await service.openAttempt(widget.questionId);
      await service.saveDraft(
        attemptId: attempt.id,
        answer: _answerDraft.text,
        solution: _solutionDraft.text,
        isCorrect: _correct,
        independent: attempt.helps.isEmpty ? _independent : null,
        delayed: _delayed,
        feedback: _feedbackDraft.text,
        checkable: _checkableDraft.text,
        uid: _draftRequest.uidFor(attempt.id),
      );
      // 写成功之后这一次请求结束；下一次保存换新的编号。
      _draftRequest.clear();
      if (!mounted) return true;
      _draftAttemptId = attempt.id;
      if (notify) {
        showToast(context, '草稿已保存，可继续补充');
      }
      return true;
    } catch (error, stack) {
      if (!mounted) return false;
      setState(
        () => _failure = describeFailure(
          context,
          error,
          stack,
          action: '保存草稿',
          kind: 'learning_draft_save',
          kept: '已经写下的内容还在页面上',
          next: '可以再点一次保存',
        ),
      );
      return false;
    }
  }

  Future<void> _saveDraftFromButton() async {
    if (_busy) return;
    await _saveDraft();
  }

  Future<void> _ask(BuddyMode mode) async {
    if (_busy) return;
    final app = AppScope.of(context);
    final service = app.chat.learning;
    setState(() {
      _busy = true;
      _failure = null;
      _result = null;
      _hint = null;
      _generating = true;
    });
    // 检查、提示与讲解都读已经保存的尝试，先把草稿落下再看题。
    final saved = await _saveDraft(notify: false);
    if (!saved) {
      if (mounted) {
        setState(() {
          _generating = false;
          _busy = false;
        });
      }
      return;
    }
    final cancel = LlmCancelToken();
    _cancelToken = cancel;
    _streamingHelp.value = '';
    try {
      final brought = app.broughtSources.identities;
      final result = await service.help(
        questionId: widget.questionId,
        mode: mode,
        broughtIdentities: brought,
        independentRedo: _independentRedo,
        cancelToken: cancel,
        onText: (text) {
          if (!mounted || !_generating) return;
          _streamingHelp.value = text;
        },
      );
      app.broughtSources.clear();
      if (!mounted) return;
      setState(() {
        _generating = false;
        _result = mergeAnswerNotice(
          answerNoticeText(result.outcome),
          result.skipped,
        );
      });
      if (!mounted) return;
      if (!result.fromModel &&
          result.notices.contains(Notice.modelNotConfigured)) {
        await _showModelGuide();
      }
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _failure = describeFailure(
          context,
          error,
          stack,
          action: '获取帮助',
          kind: 'learning_help',
          kept: '题目与草稿已经保存',
          next: '可以再试一次',
        );
      });
    } finally {
      if (identical(_cancelToken, cancel)) _cancelToken = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 停止本次生成；已经显示的部分由服务保存为一次帮助。
  void _stopHelp() {
    _cancelToken?.cancel();
  }

  /// 帮助里的记忆建议要用户点“记下”才写入，与讨论的确认卡片一致。
  Future<void> _acceptMemory(MemoryItemView item) async {
    final attempt = _view?.openAttempt;
    final helpIndex = item.helpIndex;
    if (attempt == null || helpIndex == null) return;
    await acceptMemoryCard(
      context: context,
      accept: () => AppScope.of(context).chat.learning.acceptMemory(
        attemptId: attempt.id,
        helpIndex: helpIndex,
        itemId: item.itemId,
      ),
      scope: 'learning',
      showNotice: (notice) => setState(() => _failure = notice),
    );
  }

  Future<void> _dismissMemory(MemoryItemView item) async {
    final attempt = _view?.openAttempt;
    final helpIndex = item.helpIndex;
    if (attempt == null || helpIndex == null) return;
    await dismissMemoryCard(
      context: context,
      dismiss: () => AppScope.of(context).chat.learning.dismissMemory(
        attemptId: attempt.id,
        helpIndex: helpIndex,
        itemId: item.itemId,
      ),
      scope: 'learning',
      showNotice: (notice) => setState(() => _failure = notice),
    );
  }

  Future<void> _undoMemory(MemoryItemView item) async {
    final commitId = item.commitId;
    if (commitId == null) return;
    await undoMemoryCard(
      context: context,
      commitId: commitId,
      scope: 'learning',
      showNotice: (notice) => setState(() => _failure = notice),
    );
  }

  /// 模型不可用时的引导：说明现在能做什么，并把登录入口接回调用方。
  Future<void> _showModelGuide() async {
    await showModelSetupGuide(
      context,
      dialog: true,
      title: '登录后使用学习帮助',
      content:
          '提示、讲解和检查经登录后的知新服务发出。登录之后，回答会结合当前题目与上次尝试；'
          '现在可以先写已知条件、记录卡住的地方，题目、作答与帮助都会保存在本机。'
          '登录完成回到这道题，点「用模型重新获取」，会接着回答同一个问题，不用重写题目。',
      onConfigure: _openModelAccount,
    );
  }

  Future<void> _openModelAccount() async {
    await openAccount(context);
    if (mounted) await _readConfigured();
  }

  /// 打开设置页并重新读取登录状态；返回后可以就地重新获取这一次帮助。
  Future<void> _openSettings() async {
    final result = await openModelSettingsPage(
      context,
      kind: 'learning_config_read',
      kept: '这道题与作答记录没有改动',
    );
    if (!mounted) return;
    if (result.notice != null) {
      setState(() => _failure = result.notice);
      return;
    }
    final configured = result.configured;
    if (configured == null) return;
    setState(() => _configured = configured);
    showToast(
      context,
      configured ? '模型已就绪，可以点「用模型重新获取」回答这道题。' : '登录之后才能使用模型，现在仍使用本地规则回答。',
    );
  }

  /// 进入独立重做：新建一条未提交尝试，先隐藏以前的答案与帮助，再把空白草稿
  /// 放到页面上；提交后恢复显示历次尝试。
  Future<void> _startRedo() async {
    if (_busy) return;
    final service = AppScope.of(context).chat.learning;
    setState(() {
      _busy = true;
      _failure = null;
      _result = null;
      _hint = null;
    });
    try {
      await service.openAttempt(widget.questionId, independentRedo: true);
      if (!mounted) return;
      setState(() {
        _independentRedo = true;
        _answerDraft.clear();
        _solutionDraft.clear();
        _feedbackDraft.clear();
        _checkableDraft.clear();
        _correct = null;
        _independent = null;
        _delayed = false;
        _draftAttemptId = null;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _failure = describeFailure(
          context,
          error,
          stack,
          action: '开始独立重做',
          kind: 'learning_redo_start',
          kept: '原来的草稿与历次尝试没有改动',
          next: '可以返回记录页再打开这道题',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final answer = _answerDraft.text.trim();
    if (answer.isEmpty) {
      setState(() {
        _failure = null;
        _result = null;
        _hint = '先写下答案或关键步骤，草稿会留在记录里。';
      });
      return;
    }
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _failure = null;
      _result = null;
      _hint = null;
    });
    try {
      final attempt = await scope.chat.learning.openAttempt(widget.questionId);
      await scope.chat.learning.submit(
        attemptId: attempt.id,
        answer: answer,
        solution: _solutionDraft.text,
        isCorrect: _correct,
        independent: attempt.helps.isEmpty ? _independent : null,
        delayed: _delayed,
        feedback: _feedbackDraft.text,
        checkable: _checkableDraft.text,
        uid: _submitRequest.uidFor(attempt.id),
      );
      _submitRequest.clear();
      if (!mounted) return;
      // 提交之后这条尝试不再可改：表单的复位由订阅回填新的一屏完成。
      setState(() {
        _independentRedo = false;
      });
      showToast(context, '这次作答已经记下');
    } catch (error, stack) {
      // 提交失败时把草稿整份留下，返回记录后还能接着写。
      await _saveDraft(notify: false);
      if (!mounted) return;
      setState(
        () => _failure = describeFailure(
          context,
          error,
          stack,
          action: '记录这次作答',
          kind: 'learning_submit',
          kept: '答案还留在页面上',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 返回这条记录本身的讨论；讨论里的回答在求助时直接带入，不再复制。
  Future<void> _openDiscussion() async {
    final conversationId = _view?.question.id;
    if (conversationId == null || _busy) return;
    setState(() => _busy = true);
    final saved = await _saveDraft(notify: false);
    if (mounted) setState(() => _busy = false);
    if (!saved || !mounted) return;
    await openDiscussion(context, conversationId);
  }

  /// 返回时先落下草稿，落不下就留在页面；保存成功才结束场次并退出。
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    final service = AppScope.of(context).chat.learning;
    final saved = await _saveDraft(notify: false);
    if (!saved) {
      _leaving = false;
      return;
    }
    try {
      await service.closeForQuestion(widget.questionId);
    } catch (_) {
      // 场次记录失败不改变用户已经保存的尝试与草稿。
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return LiveView<QuestionView>(
      stream: _stream,
      onData: _onQuestion,
      onError: _onQuestionError,
      builder: (context, data, loading) {
        // 只用订阅传进来的这一份：页面字段只给回调读，不参与这次渲染。
        final view = data;
        if (view == null) {
          final theme = context.zhixin;
          // 加载与首读失败都带同一条标题栏，读完标题不变，页面不跳。
          return DetailScaffold(
            header: const ZhixinHeader(title: Text('学习中'), showBack: true),
            child: _readError == null
                ? Padding(
                    padding: theme.space.pageInsets(),
                    child: const ListSkeleton(rows: 3),
                  )
                : Padding(
                    padding: theme.space.pageInsets(),
                    child: InlineNotice(
                      message: _readError!,
                      onRetry: _retryRead,
                    ),
                  ),
          );
        }
        return _questionPage(context, view);
      },
    );
  }

  Widget _questionPage(BuildContext context, QuestionView view) {
    final theme = context.zhixin;
    final attempts = view.attempts;
    final timeline = _timelineAdapter.entries;
    final sections = <Widget>[
      _questionCard(context, view),
      SizedBox(height: theme.space.md),
      _draftCard(theme),
      if (AppScope.of(context).broughtSources.length > 0) ...[
        SizedBox(height: theme.space.gap),
        _broughtSourcesRow(theme),
      ],
      SizedBox(height: theme.space.md),
      // 三个求助入口排在草稿之后，结果落在下面，提交按钮再往下，
      // 看完帮助不用往回滚就能提交。
      _helpRow(theme),
      if (_busy)
        Padding(
          padding: EdgeInsets.symmetric(vertical: theme.space.md),
          child: const forui.FProgress(),
        ),
      for (final entry in timeline)
        BuddyTimelineEntryView(adapter: _timelineAdapter, entry: entry),
      _submitSection(theme),
      if (!_independentRedo) ...[
        SectionHeading(
          title: '历次尝试',
          action: attempts.isNotEmpty && _view?.openAttempt == null
              ? forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _startRedo,
                  prefix: const Icon(FLucideIcons.refreshCw),
                  child: const Text('复查（先不看上次）'),
                )
              : null,
        ),
        if (attempts.isEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.sm),
            child: Text('提交答案后，这里会显示作答记录。', style: theme.text.bodySmall),
          ),
        for (final attempt in attempts) _attemptTile(theme, attempt),
      ] else
        Padding(
          padding: EdgeInsets.only(top: theme.space.md),
          child: Text(
            '独立重做：这次不显示以前的答案与帮助，提交后恢复显示。',
            style: theme.text.bodySmall,
          ),
        ),
      if (!_independentRedo && _recentMessages.isNotEmpty) ...[
        SectionHeading(
          title: '同一条记录里的讨论',
          action: SectionLink(
            label: '打开完整讨论',
            onPressed: _busy ? null : _openDiscussion,
          ),
        ),
        for (final message in _timelineMessages)
          ChatMessagePreview(message: message),
      ],
    ];
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: DetailScaffold(
        header: ZhixinHeader(
          title: const Text('学习中'),
          showBack: true,
          actions: [
            ZhixinHeaderButton(
              label: '讨论',
              onPressed: _busy ? null : _openDiscussion,
            ),
          ],
        ),
        // 整页按项建树：原题、草稿与提交按钮在视口里时才建，帮助、记忆与
        // 说明由时间线逐条拆成列表项，帮助正文很长时也只有滚到它才解析与排版。
        child: ListView.builder(
          padding: theme.space.pageInsets(),
          itemCount: sections.length,
          itemBuilder: (context, index) => sections[index],
        ),
      ),
    );
  }

  /// 原题卡：题干、出处、材料摘录与可点开的原图。
  Widget _questionCard(BuildContext context, QuestionView view) {
    final theme = context.zhixin;
    final question = view.question;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question.displayStem, style: theme.text.titleMedium),
            if (question.sourceRef != null) ...[
              SizedBox(height: theme.space.tight),
              Text('出处：${question.sourceRef}', style: theme.text.bodySmall),
            ],
            if (question.contextText != null) ...[
              SizedBox(height: theme.space.tight),
              Text('材料：${question.contextText}', style: theme.text.bodySmall),
            ],
            if (question.imagePaths.isNotEmpty) ...[
              SizedBox(height: theme.space.sm),
              Wrap(
                spacing: theme.space.sm,
                runSpacing: theme.space.sm,
                children: [
                  for (final path in question.imagePaths)
                    GestureDetector(
                      // 原图点开看大图，与讨论里的图片同一处实现。
                      onTap: () => showImagePreview(
                        context,
                        AppScope.of(context).paths.resolveImage(path),
                      ),
                      child: ClipRRect(
                        borderRadius: theme.radius.tag,
                        child: Image.file(
                          File(AppScope.of(context).paths.resolveImage(path)),
                          width: 150,
                          height: 120,
                          // 原题图片按显示宽度解码，不把 1600 像素的图整张放进内存。
                          cacheWidth:
                              (150 * MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: theme.colors.surfaceContainerHigh,
                            child: SizedBox(
                              width: 150,
                              height: 120,
                              child: Center(
                                child: Text(
                                  '本机没有这张原图',
                                  style: theme.text.bodySmall.copyWith(
                                    color: theme.colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 从查找结果带入的来源只用于下一次回答，发送后清空。
  Widget _broughtSourcesRow(ZhixinTheme theme) {
    final count = AppScope.of(context).broughtSources.length;
    return Row(
      children: [
        Icon(FLucideIcons.listChecks, size: 16, color: theme.colors.primary),
        SizedBox(width: theme.space.xs),
        Expanded(
          child: Text('已加入 $count 条来源，本次回答后清除。', style: theme.text.bodySmall),
        ),
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () =>
              setState(() => AppScope.of(context).broughtSources.clear()),
          child: const Text('不带入'),
        ),
      ],
    );
  }

  /// 提示、讲解与检查：三个小号描边按钮同排，生成中另给停止入口。
  Widget _helpRow(ZhixinTheme theme) {
    Widget button(String label, BuddyMode mode) => forui.FButton(
      variant: forui.FButtonVariant.outline,
      size: forui.FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.max,
      onPress: _busy ? null : () => _ask(mode),
      child: Text(label),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: button('提示', BuddyMode.hint)),
            SizedBox(width: theme.space.sm),
            Expanded(child: button('讲解', BuddyMode.explain)),
            SizedBox(width: theme.space.sm),
            Expanded(child: button('检查', BuddyMode.check)),
          ],
        ),
        if (_generating)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: EdgeInsets.only(top: theme.space.sm),
              child: forui.FButton(
                variant: forui.FButtonVariant.outline,
                size: forui.FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: _stopHelp,
                prefix: const Icon(FLucideIcons.square),
                child: const Text('停止生成'),
              ),
            ),
          ),
      ],
    );
  }

  /// 自评与提交：看完帮助再判断这次做得怎样，提交按钮占满整行。
  Widget _submitSection(ZhixinTheme theme) {
    final helps = _view?.openAttempt?.helps.length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: theme.space.sectionTop),
        Text('这次做对了吗', style: theme.text.bodyMedium),
        SizedBox(height: theme.space.xs),
        IgnorePointer(
          ignoring: _busy,
          child: ZhixinSegmented<bool?>(
            segments: const [
              ZhixinSegment(value: true, label: '做对了'),
              ZhixinSegment(value: false, label: '做错了'),
              ZhixinSegment(value: null, label: '暂不判断'),
            ],
            selected: _correct,
            onChanged: (value) => setState(() => _correct = value),
          ),
        ),
        if (helps > 0)
          Padding(
            padding: EdgeInsets.only(top: theme.space.sm),
            child: Text(
              '本次已使用应用内帮助 $helps 次，提交后按「辅助完成」记录。',
              style: theme.text.bodySmall,
            ),
          ),
        SizedBox(height: theme.space.md),
        forui.FButton(
          mainAxisSize: MainAxisSize.max,
          onPress: _busy ? null : _submit,
          child: const Text('提交作答'),
        ),
      ],
    );
  }

  /// 学习页底部只带最近三条讨论，完整历史仍打开讨论页。
  List<ChatMessage> get _timelineMessages {
    if (_recentMessages.length <= 3) return _recentMessages;
    return _recentMessages.sublist(_recentMessages.length - 3);
  }

  /// 作答草稿放在原题下面：先写几步，再点检查；提交前都可以继续改。
  Widget _draftCard(ZhixinTheme theme) {
    final helps = _view?.openAttempt?.helps.length ?? 0;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          theme.space.lg,
          theme.space.sm,
          theme.space.lg,
          theme.space.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('作答草稿', style: theme.text.titleSmall)),
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _saveDraftFromButton,
                  child: const Text('保存草稿'),
                ),
              ],
            ),
            forui.FTextField(
              control: .managed(controller: _answerDraft),
              enabled: !_busy,
              minLines: 2,
              maxLines: 8,
              label: const Text('答案或关键步骤'),
              hint: '先写已知条件与推到的步骤，再点「检查」请搭子看第一步',
            ),
            SizedBox(height: theme.space.gap),
            forui.FTextField(
              control: .managed(controller: _solutionDraft),
              enabled: !_busy,
              minLines: 1,
              maxLines: 6,
              label: const Text('解法（可选）'),
              hint: '整理后单独保存，不覆盖答案、帮助与困难',
            ),
            SizedBox(height: theme.space.gap),
            forui.FAccordion(
              style: .delta(
                titlePadding: .value(
                  EdgeInsets.symmetric(vertical: theme.space.sm),
                ),
                childPadding: .value(EdgeInsets.only(bottom: theme.space.xs)),
                dividerStyle: .delta(color: Colors.transparent),
              ),
              children: [
                forui.FAccordionItem(
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('补充依据（可选）', style: theme.text.titleSmall),
                      SizedBox(height: theme.space.xs / 2),
                      Text('独立性、间隔、困难与核对依据', style: theme.text.bodySmall),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (helps == 0) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text('这次是否独立完成', style: theme.text.bodyMedium),
                        ),
                        SizedBox(height: theme.space.xs),
                        // 三选一改成互斥的分段控件：点按区域更大，也能看出只能选一个。
                        IgnorePointer(
                          ignoring: _busy,
                          child: ZhixinSegmented<String?>(
                            segments: const [
                              ZhixinSegment(
                                value: 'independent',
                                label: '独立完成',
                              ),
                              ZhixinSegment(
                                value: 'external',
                                label: '用了应用外帮助',
                              ),
                              ZhixinSegment(value: null, label: '未说明'),
                            ],
                            selected: switch (_independent) {
                              true => 'independent',
                              false => 'external',
                              null => null,
                            },
                            onChanged: (value) => setState(
                              () => _independent = switch (value) {
                                'independent' => true,
                                'external' => false,
                                _ => null,
                              },
                            ),
                          ),
                        ),
                        SizedBox(height: theme.space.gap),
                      ],
                      forui.FSwitch(
                        label: const Text('间隔后重做'),
                        description: const Text('系统会单独记录间隔后的独立表现。'),
                        value: _delayed,
                        enabled: !_busy,
                        onChange: (value) => setState(() => _delayed = value),
                      ),
                      forui.FTextField(
                        control: .managed(controller: _feedbackDraft),
                        enabled: !_busy,
                        label: const Text('遇到的困难（可选）'),
                      ),
                      forui.FTextField(
                        control: .managed(controller: _checkableDraft),
                        enabled: !_busy,
                        label: const Text('核对依据（可选）'),
                        hint: '标准答案、测试结果等；只作为你的依据保存',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _attemptTile(ZhixinTheme theme, Attempt attempt) {
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TagRow(
                      children: [
                        if (attempt.submitted) ...[
                          StatusTag(attempt.selfResult),
                          StatusTag(
                            attempt.judgmentLabel,
                            tone: switch (attempt.isCorrect) {
                              true => TagTone.accent,
                              false => TagTone.attention,
                              null => TagTone.muted,
                            },
                          ),
                        ] else
                          // 未提交的草稿是这一页最需要留意的状态，用留意色标出。
                          const StatusTag('未提交的草稿', tone: TagTone.attention),
                      ],
                    ),
                  ),
                  SizedBox(width: theme.space.sm),
                  Text(
                    attempt.submittedAt == null
                        ? ''
                        : shortTime(attempt.submittedAt!),
                    style: theme.text.bodySmall,
                  ),
                ],
              ),
              if (attempt.userAnswer != null) ...[
                SizedBox(height: theme.space.tight),
                Text('作答：${attempt.userAnswer}', style: theme.text.bodyMedium),
              ],
              if (attempt.solution?.trim().isNotEmpty ?? false) ...[
                SizedBox(height: theme.space.tight),
                Text(
                  '解法：${attempt.solution!.trim()}',
                  style: theme.text.bodyMedium,
                ),
              ],
              if (attempt.feedback?.trim().isNotEmpty ?? false) ...[
                SizedBox(height: theme.space.tight),
                Text(
                  '困难：${attempt.feedback!.trim()}',
                  style: theme.text.bodyMedium,
                ),
              ],
              if (attempt.helps.isNotEmpty) ...[
                SizedBox(height: theme.space.tight),
                Text(
                  '应用内帮助 ${attempt.helps.length} 次',
                  style: theme.text.bodySmall,
                ),
                if (attempt.helps.length <= 2 ||
                    _expandedHelps.contains(attempt.id))
                  for (final help in attempt.helps)
                    Padding(
                      padding: EdgeInsets.only(top: theme.space.xs / 2),
                      child: Text(
                        '· ${_helpLabel(help.kind)}：${help.content}',
                        style: theme.text.bodySmall,
                      ),
                    )
                else
                  for (final help in attempt.helps.reversed.take(2))
                    Padding(
                      padding: EdgeInsets.only(top: theme.space.xs / 2),
                      child: Text(
                        '· ${_helpLabel(help.kind)}：${_shorten(help.content)}',
                        style: theme.text.bodySmall,
                      ),
                    ),
                if (attempt.helps.length > 2)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => setState(() {
                        if (!_expandedHelps.remove(attempt.id)) {
                          _expandedHelps.add(attempt.id);
                        }
                      }),
                      child: Text(
                        _expandedHelps.contains(attempt.id)
                            ? '收起较早帮助'
                            : '查看全部 ${attempt.helps.length} 次帮助',
                      ),
                    ),
                  ),
              ],
              if (attempt.submitted) ...[
                SizedBox(height: theme.space.gap),
                const CardDivider(gap: 0),
                Padding(
                  padding: EdgeInsets.only(top: theme.space.xs),
                  child: Text(
                    '依据：${attempt.selfBasis}',
                    style: theme.text.bodySmall,
                  ),
                ),
                for (final assessment
                    in _assessments[attempt.id] ?? const <Assessment>[])
                  Padding(
                    padding: EdgeInsets.only(top: theme.space.xs),
                    child: Text(
                      '${assessment.kind.label}：${assessment.result}'
                      '${assessment.basis == null ? '' : '\n依据：${assessment.basis}'}',
                      style: theme.text.bodySmall,
                    ),
                  ),
              ],
              if (attempt.submitted && !_busy)
                Align(
                  alignment: Alignment.centerRight,
                  child: forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _assess(attempt),
                    child: const Text('检查作答依据'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _assess(Attempt attempt) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final app = AppScope.of(context);
      await app.chat.learning.assessWithModel(
        questionId: widget.questionId,
        attemptId: attempt.id,
        broughtIdentities: app.broughtSources.identities,
        uid: _assessRequest.uidFor(attempt.id),
      );
      app.broughtSources.clear();
      _assessRequest.clear();
      if (!mounted) return;
      showToast(context, '模型判断已记录');
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _failure = describeFailure(
          context,
          error,
          stack,
          action: '获取模型判断',
          kind: 'learning_assess',
          kept: '这次作答与已有判断没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _helpLabel(String kind) => switch (kind) {
    'hint' => '提示',
    'explain' => '讲解',
    'check' => '检查',
    'discuss' => '讨论',
    _ => '帮助',
  };

  String _shorten(String text, {int limit = 80}) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return truncateCodePoints(cleaned, limit);
  }
}

/// 学习页时间线的取数：帮助、记忆、说明与回执都从当前未提交尝试读。
class _LearningTimeline extends BuddyTimelineAdapter {
  _LearningTimeline(this._state);

  final _LearningPageState _state;

  @override
  List<BuddyTimelineEntry> get entries {
    final state = _state;
    final latest = state._view?.openAttempt?.helps.lastOrNull;
    final help = state._generating || latest?.fromModel == null ? null : latest;
    final mode = switch (help?.kind) {
      'hint' => BuddyMode.hint,
      'explain' => BuddyMode.explain,
      'check' => BuddyMode.check,
      _ => null,
    };
    final notices = help?.notices ?? const [];
    final retry =
        notices.contains(Notice.modelCallFailed) ||
        notices.contains(Notice.generationInterrupted) ||
        notices.contains(Notice.answerTruncated) ||
        notices.contains(Notice.userStopped);
    final saved = SavedAnswerStatus(
      notices: notices,
      failure: llmFailureFromName(help?.failureName),
      quotaReason: QuotaExhaustedReason.fromName(help?.quotaReason),
    );
    // 失败、回答收尾与页面引导各自一格；回答收尾在没有本地提示时用保存的状态写。
    final failure = state._failure;
    final notice =
        failure ??
        state._result ??
        state._hint ??
        savedAnswerNoticeText(saved, keptPartial: help?.fromModel == true);
    return [
      if (help != null || state._generating)
        BuddyHelpEntry(
          text: help?.content,
          generating: state._generating,
          streaming: state._streamingHelp,
        ),
      for (final item in state._memoryItems) BuddyMemoryEntry(item),
      if (notice != null)
        BuddyNoticeEntry(
          message: notice,
          failed: failure != null,
          actions: [
            if (mode != null && (retry || help?.fromModel == false))
              ModelRecoveryButtons(
                signedIn: state._configured,
                primaryLabel: retry ? '重试这次回答' : '用模型重新获取',
                onPrimary: () => state._ask(mode),
                onSignIn: state._openModelAccount,
                onOpenSettings:
                    saved.needsConfig ||
                        saved.failure == LlmFailure.modelNotAllowed
                    ? state._openSettings
                    : null,
                onPurchasePoints:
                    saved.failure == LlmFailure.quotaExhausted &&
                        (saved.quotaReason == QuotaExhaustedReason.account ||
                            saved.quotaReason == QuotaExhaustedReason.points)
                    ? () => openAccount(state.context)
                    : null,
                enabled: !state._busy,
              ),
          ],
        ),
    ];
  }

  @override
  String imagePath(String stored) =>
      AppScope.of(_state.context).paths.resolveImage(stored);

  @override
  void acceptMemory(MemoryItemView item) => _state._acceptMemory(item);

  @override
  void dismissMemory(MemoryItemView item) => _state._dismissMemory(item);

  @override
  void undoMemory(MemoryItemView item) => _state._undoMemory(item);
}

/// 作答草稿的七项内容：四段文字、自评、独立性与间隔标记。
///
/// 有没有内容、与已经保存的草稿是否一致，都在这一个值对象上判断一次；原先
/// `_hasDraftContent`、`_savedDraftHasContent` 与 `_draftDiffersFromSaved`
/// 逐项比较同一批字段，改一处容易漏另一处。文本比较去掉首尾空白，避免只差
/// 空格的草稿反复写提交。
class _AnswerDraft {
  const _AnswerDraft({
    this.answer = '',
    this.solution = '',
    this.feedback = '',
    this.checkable = '',
    this.correct,
    this.independent,
    this.delayed = false,
  });

  /// 从已经保存的尝试读回；有应用内帮助时不再记独立完成。
  factory _AnswerDraft.from(
    Attempt? attempt,
    String Function(String? attemptId) checkableOf,
  ) {
    if (attempt == null) return const _AnswerDraft();
    return _AnswerDraft(
      answer: attempt.userAnswer ?? '',
      solution: attempt.solution ?? '',
      feedback: attempt.feedback ?? '',
      checkable: checkableOf(attempt.id),
      correct: attempt.isCorrect,
      independent: attempt.helps.isEmpty ? attempt.independent : null,
      delayed: attempt.delayed,
    );
  }

  final String answer;
  final String solution;
  final String feedback;
  final String checkable;
  final bool? correct;
  final bool? independent;
  final bool delayed;

  bool get hasContent =>
      answer.trim().isNotEmpty ||
      solution.trim().isNotEmpty ||
      feedback.trim().isNotEmpty ||
      checkable.trim().isNotEmpty ||
      correct != null ||
      independent != null ||
      delayed;

  @override
  bool operator ==(Object other) =>
      other is _AnswerDraft &&
      other.answer.trim() == answer.trim() &&
      other.solution.trim() == solution.trim() &&
      other.feedback.trim() == feedback.trim() &&
      other.checkable.trim() == checkable.trim() &&
      other.correct == correct &&
      other.independent == independent &&
      other.delayed == delayed;

  @override
  int get hashCode => Object.hash(
    answer.trim(),
    solution.trim(),
    feedback.trim(),
    checkable.trim(),
    correct,
    independent,
    delayed,
  );
}

/// 一次动作的请求身份：同一条尝试上重试沿用同一个编号，换一条就换编号。
///
/// 保存草稿、提交作答与模型判断原先各写两个字段加一个取号方法，成功后各自
/// 置空；现在三处各持一个实例，取值与复位只在这里。
class _RequestIdentity {
  String? _attemptId;
  String? _uid;

  String uidFor(String attemptId) {
    if (_attemptId != attemptId) {
      _attemptId = attemptId;
      _uid = newUuidV7();
    }
    return _uid!;
  }

  void clear() {
    _attemptId = null;
    _uid = null;
  }
}
