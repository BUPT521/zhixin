import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../app_scope.dart';
import '../domain/models/buddy_protocol.dart';
import '../application/buddy_actions.dart';
import '../application/learning_service.dart';
import '../application/memory_view.dart';
import '../domain/models/assessment.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/question.dart';
import 'discussion_cards.dart';
import 'discussion_page.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'markdown_text.dart';
import 'settings_page.dart';
import 'undo_feedback.dart';
import 'zhixin_chip.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 学习中：原题、历次尝试、提示与讲解，以及这次的结果。
class LearningPage extends StatefulWidget {
  const LearningPage({
    super.key,
    required this.questionId,
    this.startRedo = false,
  });

  final int questionId;

  /// 从记录页的复查入口进入时直接进入独立重做，不再让用户先点一次。
  final bool startRedo;

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
  QuestionView? _view;
  Map<int, List<Assessment>> _assessments = const {};
  bool _loading = true;
  bool _busy = false;
  String? _help;
  String? _notice;
  List<AppliedChange> _changeItems = const [];

  /// 当前未提交尝试上的记忆建议：待确认的可以「记下」，已写入的可以撤销。
  List<MemoryItemView> _memoryItems = const [];
  bool _started = false;
  bool _leaving = false;

  /// 生成中的帮助只重建结果卡片，不带着整页题目与历次尝试一起重建。
  final ValueNotifier<String> _streamingHelp = ValueNotifier<String>('');
  bool _generating = false;
  LlmCancelToken? _cancelToken;

  /// 已经展开全部帮助的尝试；默认只显示最近两条，更早的仍然可以查看。
  final Set<int> _expandedHelps = <int>{};

  /// 是否已经配置模型，以及上一次求助的模式与来源；用来决定配置后能否重取。
  bool _configured = false;
  BuddyMode? _lastMode;
  bool _lastFromModel = true;
  bool _lastInterrupted = false;

  /// 作答草稿留在学习页上，检查与提交都读这一份；未提交的尝试是它的保存处。
  final _answerDraft = TextEditingController();
  final _solutionDraft = TextEditingController();
  final _feedbackDraft = TextEditingController();
  final _checkableDraft = TextEditingController();
  bool? _correct;
  bool? _independent;
  bool _delayed = false;
  int? _draftAttemptId;

  /// 保存草稿与提交各保留一个请求编号：写入失败后用户再点一次时沿用同一个
  /// 编号，数据层按提交去重，不会重复写一条草稿或多提交一次作答。
  String? _draftRequestId;
  int? _draftRequestAttemptId;
  String? _submitRequestId;
  int? _submitRequestAttemptId;
  String? _assessRequestId;
  int? _assessRequestAttemptId;

  /// 用户选择先不看上次答案重做时，隐藏历次尝试，求助不带入旧讨论回答与困难。
  bool _independentRedo = false;

  /// 从记录页复查入口进入时，第一次读取之后自动进入独立重做。
  bool _autoRedoStarted = false;

  /// 同一条记录最近几条讨论消息；学习页把讨论与作答放在一起，完整讨论另开。
  List<ChatMessage> _recentMessages = const [];

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
    _load();
  }

  Future<void> _load({bool reapplyDraft = false}) async {
    final scope = AppScope.of(context);
    try {
      final view = await scope.learningService.view(widget.questionId);
      final open = view.openAttempt;
      // 判断、记忆建议、模型配置与最近讨论互不依赖，同时读取。
      final (assessments, memoryItems, config, messages) = await (
        scope.learningService.assessmentsFor(view.attempts),
        open == null
            ? Future<List<MemoryItemView>>.value(const [])
            : scope.learningService.memoryItemsFor(open),
        scope.settingsService.config(),
        scope.conversations.recent(widget.questionId, limit: 6),
      ).wait;
      if (!mounted) return;
      setState(() {
        _view = view;
        _assessments = assessments;
        _memoryItems = memoryItems;
        _configured = config?.isConfigured ?? false;
        _recentMessages = messages;
        _independentRedo = open?.redoOfAttemptId != null;
        _loading = false;
        _applyDraft(view.openAttempt, force: reapplyDraft);
      });
      if (widget.startRedo &&
          !_autoRedoStarted &&
          view.openAttempt == null &&
          view.attempts.any((attempt) => attempt.submitted)) {
        _autoRedoStarted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _startRedo();
        });
      }
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取这道题与作答记录',
          kind: 'learning_read',
          kept: '本机记录没有改动',
          next: '可以返回记录页再打开',
        );
      });
    }
  }

  /// 把未提交的尝试读回草稿；同一条尝试上的修改不覆盖用户正在写的内容。
  void _applyDraft(Attempt? attempt, {bool force = false}) {
    final helped = attempt?.helps.isNotEmpty ?? false;
    if (!force && attempt?.id == _draftAttemptId) {
      if (helped) _independent = null;
      return;
    }
    _draftAttemptId = attempt?.id;
    _answerDraft.text = attempt?.userAnswer ?? '';
    _solutionDraft.text = attempt?.solution ?? '';
    _feedbackDraft.text = attempt?.feedback ?? '';
    _checkableDraft.text = _checkableOf(attempt?.id);
    _correct = attempt?.isCorrect;
    _independent = helped ? null : attempt?.independent;
    _delayed = attempt?.delayed ?? false;
  }

  /// 草稿里已经填过核对依据时带回来；之后的修改直接覆盖同一条判断。
  String _checkableOf(int? attemptId) {
    if (attemptId == null) return '';
    for (final assessment
        in (_assessments[attemptId] ?? const <Assessment>[]).reversed) {
      if (assessment.kind == AssessmentKind.user) return assessment.result;
    }
    return '';
  }

  bool get _hasDraftContent =>
      _answerDraft.text.trim().isNotEmpty ||
      _solutionDraft.text.trim().isNotEmpty ||
      _feedbackDraft.text.trim().isNotEmpty ||
      _checkableDraft.text.trim().isNotEmpty ||
      _correct != null ||
      _independent != null ||
      _delayed;

  /// 已经存下的草稿是否有内容；没有时离开页面不必再写一条空草稿。
  bool _savedDraftHasContent(Attempt? attempt) {
    if (attempt == null) return false;
    return (attempt.userAnswer?.trim().isNotEmpty ?? false) ||
        (attempt.solution?.trim().isNotEmpty ?? false) ||
        (attempt.feedback?.trim().isNotEmpty ?? false) ||
        attempt.isCorrect != null ||
        attempt.independent != null ||
        attempt.delayed ||
        _checkableOf(attempt.id).isNotEmpty;
  }

  /// 当前表单与已经保存的草稿是否有差别；没有差别时不重复写提交。
  bool _draftDiffersFromSaved(Attempt? attempt) {
    if (attempt == null) return _hasDraftContent;
    final savedIndependent = attempt.helps.isEmpty ? attempt.independent : null;
    return (attempt.userAnswer ?? '') != _answerDraft.text.trim() ||
        (attempt.solution ?? '') != _solutionDraft.text.trim() ||
        (attempt.feedback ?? '') != _feedbackDraft.text.trim() ||
        attempt.isCorrect != _correct ||
        savedIndependent != _independent ||
        attempt.delayed != _delayed ||
        _checkableOf(attempt.id) != _checkableDraft.text.trim();
  }

  /// 保存整份草稿；检查、提交与离开学习页之前都先调用它。
  /// 同一份草稿或同一次提交的重试沿用同一个请求编号；换了一条尝试就换编号。
  String _requestIdForDraft(int attemptId) {
    if (_draftRequestAttemptId != attemptId) {
      _draftRequestAttemptId = attemptId;
      _draftRequestId =
          'draft-$attemptId-${DateTime.now().microsecondsSinceEpoch}';
    }
    return _draftRequestId!;
  }

  String _requestIdForSubmit(int attemptId) {
    if (_submitRequestAttemptId != attemptId) {
      _submitRequestAttemptId = attemptId;
      _submitRequestId =
          'submit-$attemptId-${DateTime.now().microsecondsSinceEpoch}';
    }
    return _submitRequestId!;
  }

  String _requestIdForAssess(int attemptId) {
    if (_assessRequestAttemptId != attemptId) {
      _assessRequestAttemptId = attemptId;
      _assessRequestId =
          'assess-$attemptId-${DateTime.now().microsecondsSinceEpoch}';
    }
    return _assessRequestId!;
  }

  Future<bool> _saveDraft({bool notify = true}) async {
    final open = _view?.openAttempt;
    if (!_hasDraftContent && !_savedDraftHasContent(open)) {
      if (notify && mounted) {
        showToast(context, '还没有写下草稿');
      }
      return true;
    }
    if (!_draftDiffersFromSaved(open)) {
      if (notify && mounted) {
        showToast(context, '草稿已保存，可继续补充');
      }
      return true;
    }
    final service = AppScope.of(context).learningService;
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
        requestId: _requestIdForDraft(attempt.id),
      );
      // 写成功之后这一次请求结束；下一次保存换新的编号。
      _draftRequestId = null;
      _draftRequestAttemptId = null;
      if (!mounted) return true;
      _draftAttemptId = attempt.id;
      await _load();
      if (!mounted) return true;
      if (notify) {
        showToast(context, '草稿已保存，可继续补充');
      }
      return true;
    } catch (error, stack) {
      if (!mounted) return false;
      setState(
        () => _notice = describeFailure(
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
    final service = app.learningService;
    setState(() {
      _busy = true;
      _notice = null;
      _changeItems = const [];
      _help = null;
      _lastInterrupted = false;
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
        _help = result.text.trim().isEmpty ? null : result.text;
        _notice = result.notice;
        _changeItems = result.changes;
        _lastMode = mode;
        _lastFromModel = result.fromModel;
        _lastInterrupted = result.interrupted;
      });
      await _load();
      if (!mounted) return;
      if (!result.fromModel && (_notice?.contains('尚未配置') ?? false)) {
        await _showModelGuide();
      }
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _help = null;
        _notice = describeFailure(
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

  /// 撤销与安排页、讨论卡片、记忆页走同一条入口：提示、重读与失败说明一致。
  Future<void> _undoChange(int commitId) => undoCommitWithFeedback(
    context,
    commitId,
    onUndone: () => setState(
      () => _changeItems = _changeItems
          .where((change) => change.commitId != commitId)
          .toList(growable: false),
    ),
    reload: _load,
  );

  /// 帮助里的记忆建议要用户点“记下”才写入，与讨论的确认卡片一致。
  Future<void> _acceptMemory(MemoryItemView item) async {
    final attempt = _view?.openAttempt;
    if (attempt == null) return;
    try {
      final result = await AppScope.of(context).learningService.acceptMemory(
        attemptId: attempt.id,
        helpIndex: item.ownerId,
        itemId: item.itemId,
        requestId: 'memory-${attempt.id}-${item.ownerId}-${item.itemId}',
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      // 写入后的回执就是这张卡片本身，不再另加一行，避免两处撤销。
      showToast(context, result.notice ?? '已记下这条记忆');
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存这条记忆',
          kind: 'learning_memory_accept',
          kept: '这条记忆仍在待确认',
          next: '可以再点一次「记下」',
        ),
      );
    }
  }

  Future<void> _dismissMemory(MemoryItemView item) async {
    final attempt = _view?.openAttempt;
    if (attempt == null) return;
    try {
      await AppScope.of(context).learningService.dismissMemory(
        attemptId: attempt.id,
        helpIndex: item.ownerId,
        itemId: item.itemId,
      );
      if (mounted) await _load();
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '收起这条记忆',
          kind: 'learning_memory_dismiss',
          kept: '记忆卡片还在页面上',
          next: '可以再试一次',
        ),
      );
    }
  }

  /// 点开原题缩略图看大图；图片文件不在了就说明，不弹空白页。
  Future<void> _showImage(String path) async {
    final file = File(AppScope.of(context).paths.resolveImage(path));
    if (!await file.exists()) {
      if (!mounted) return;
      showToast(context, '这张原图在本机已经找不到');
      return;
    }
    if (!mounted) return;
    // 遮挡层、进出动画与圆角跟页面里的其他对话框一致；对话框默认限制宽度
    // 280 到 560，看图时改成占满屏宽只留外边距，横屏与平板上不会被压窄。
    final media = MediaQuery.of(context);
    final size = media.size;
    // 手机拍的原图直接解码要占几十 MB：按屏宽 × dpr × 2 设解码尺寸，与看图
    // 的 4 倍放大配合已经够清晰。大图解码好之前先用同一张图的小尺寸垫底，
    // 点开时不会先白屏，也不用等原图。
    final decodeWidth = (size.width * media.devicePixelRatio * 2).round();
    final thumbWidth = (size.width * media.devicePixelRatio).round();
    await forui.showFDialog<void>(
      context: context,
      builder: (context, style, animation) => forui.FDialog(
        animation: animation,
        clipBehavior: Clip.antiAlias,
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: size.width - 24,
          maxHeight: size.height - 24,
        ),
        builder: (context, style) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Image.file(
            file,
            cacheWidth: decodeWidth,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return Image.file(file, cacheWidth: thumbWidth);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _showModelGuide() async {
    final go = await showZhixinAlert<bool>(
      context: context,
      title: '配置模型以使用学习帮助',
      content: const Text(
        '提示、讲解和检查由你配置的模型提供。配置后，回答会结合当前题目与上次尝试；'
        '现在可以先写已知条件、记录卡住的地方，题目、作答与帮助都会保存在本机。'
        '配置完成后回到这道题，点「用模型重新获取」，会接着回答同一个问题，不用重写题目。',
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('继续本地使用'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('前往设置'),
        ),
      ],
    );
    if (go == true && mounted) await _openSettings();
  }

  /// 打开设置页并重新读取配置；返回后可以就地重新获取这一次帮助。
  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    if (!mounted) return;
    try {
      final config = await AppScope.of(context).settingsService.config();
      if (!mounted) return;
      setState(() => _configured = config?.isConfigured ?? false);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取模型配置',
          kind: 'learning_config_read',
          kept: '这道题与作答记录没有改动',
          next: '可以回到设置页重新保存一次',
        ),
      );
      return;
    }
    if (!mounted) return;
    showToast(
      context,
      _configured ? '模型已就绪，可以点「用模型重新获取」回答这道题。' : '模型还没有配置完整，仍使用本地规则回答。',
    );
  }

  /// 配置好模型之后，用同一种方式重新请求一次帮助。
  Future<void> _retryHelp() async {
    final mode = _lastMode;
    if (mode == null) return;
    await _ask(mode);
  }

  /// 进入独立重做：新建一条未提交尝试，先隐藏以前的答案与帮助，再把空白草稿
  /// 放到页面上；提交后恢复显示历次尝试。
  Future<void> _startRedo() async {
    if (_busy) return;
    final service = AppScope.of(context).learningService;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await service.openAttempt(widget.questionId, independentRedo: true);
      if (!mounted) return;
      setState(() {
        _independentRedo = true;
        _help = null;
        _answerDraft.clear();
        _solutionDraft.clear();
        _feedbackDraft.clear();
        _checkableDraft.clear();
        _correct = null;
        _independent = null;
        _delayed = false;
        _draftAttemptId = null;
      });
      await _load(reapplyDraft: true);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
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
      setState(() => _notice = '先写下答案或关键步骤，草稿会留在记录里。');
      return;
    }
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final attempt = await scope.learningService.openAttempt(
        widget.questionId,
      );
      await scope.learningService.submit(
        attemptId: attempt.id,
        answer: answer,
        solution: _solutionDraft.text,
        isCorrect: _correct,
        independent: attempt.helps.isEmpty ? _independent : null,
        delayed: _delayed,
        feedback: _feedbackDraft.text,
        checkable: _checkableDraft.text,
        requestId: _requestIdForSubmit(attempt.id),
      );
      _submitRequestId = null;
      _submitRequestAttemptId = null;
      if (mounted) setState(() => _independentRedo = false);
      await _load(reapplyDraft: true);
      if (!mounted) return;
      setState(() => _help = null);
      showToast(context, '这次作答已经记下');
    } catch (error, stack) {
      // 提交失败时把草稿整份留下，返回记录后还能接着写。
      await _saveDraft(notify: false);
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: conversationId),
      ),
    );
    if (mounted) await _load();
  }

  /// 返回时先落下草稿，落不下就留在页面；保存成功才结束场次并退出。
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    final service = AppScope.of(context).learningService;
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
    final theme = context.zhixin;
    if (_loading) {
      return const DetailScaffold(
        child: Center(child: forui.FCircularProgress()),
      );
    }
    final view = _view;
    if (view == null) {
      return DetailScaffold(
        header: const ZhixinHeader(title: Text('题目'), showBack: true),
        child: Center(child: Text(_notice ?? '未找到这道题')),
      );
    }
    final attempts = view.attempts;
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
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : _openDiscussion,
              child: const Text('讨论'),
            ),
          ],
        ),
        child: ListView(
          padding: theme.space.pageInsets(),
          children: [
            forui.FCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.question.displayStem,
                      style: theme.text.titleMedium,
                    ),
                    if (view.question.sourceRef != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '出处：${view.question.sourceRef}',
                        style: theme.text.bodySmall,
                      ),
                    ],
                    if (view.question.contextText != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '材料：${view.question.contextText}',
                        style: theme.text.bodySmall,
                      ),
                    ],
                    if (view.question.imagePaths.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final path in view.question.imagePaths)
                            GestureDetector(
                              onTap: () => _showImage(path),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(
                                    AppScope.of(context).paths
                                        .resolveImage(path),
                                  ),
                                  width: 150,
                                  height: 120,
                                  // 原题图片按显示宽度解码，不把 1600 像素的图整张放进内存。
                                  cacheWidth:
                                      (150 *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round(),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _draftCard(theme),
            const SizedBox(height: 8),
            if (AppScope.of(context).broughtSources.length > 0) ...[
              Row(
                children: [
                  Icon(
                    FLucideIcons.listChecks,
                    size: 16,
                    color: theme.colors.primary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '已加入 ${AppScope.of(context).broughtSources.length} 条来源，'
                      '本次回答后清除。',
                      style: theme.text.bodySmall,
                    ),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => setState(
                      () => AppScope.of(context).broughtSources.clear(),
                    ),
                    child: const Text('不带入'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                forui.FButton(
                  variant: forui.FButtonVariant.secondary,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : () => _ask(BuddyMode.hint),
                  child: const Text('提示'),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.secondary,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : () => _ask(BuddyMode.explain),
                  child: const Text('讲解'),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.secondary,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : () => _ask(BuddyMode.check),
                  child: const Text('检查'),
                ),
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _submit,
                  child: const Text('提交作答'),
                ),
                if (_generating)
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _stopHelp,
                    prefix: const Icon(FLucideIcons.square),
                    child: const Text('停止生成'),
                  ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: forui.FProgress(),
              ),
            if (_help != null || _generating) ...[
              const SizedBox(height: 12),
              forui.FCard(
                style: .delta(
                  decoration: .shapeDelta(
                    color: theme.colors.secondaryContainer,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: _generating
                      ? ValueListenableBuilder<String>(
                          valueListenable: _streamingHelp,
                          builder: (context, text, _) => text.trim().isEmpty
                              ? Row(
                                  children: [
                                    const forui.FCircularProgress(size: .xs),
                                    const SizedBox(width: 8),
                                    Text('正在生成', style: theme.text.bodySmall),
                                  ],
                                )
                              : MarkdownText(text, streaming: true),
                        )
                      : MarkdownText(_help!),
                ),
              ),
            ],
            for (final item in _memoryItems)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: MemoryCard(
                  item: item,
                  onAccept: () => _acceptMemory(item),
                  onDismiss: () => _dismissMemory(item),
                  onUndo: () {
                    final commitId = item.commitId;
                    if (commitId != null) _undoChange(commitId);
                  },
                ),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_notice!, style: TextStyle(color: theme.colors.error)),
                    if (_help != null && (!_lastFromModel || _lastInterrupted))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (_configured)
                              forui.FButton(
                                variant: forui.FButtonVariant.secondary,
                                mainAxisSize: MainAxisSize.min,
                                onPress: _busy ? null : _retryHelp,
                                prefix: const Icon(FLucideIcons.refreshCw),
                                child: Text(
                                  _lastInterrupted ? '重试这次回答' : '用模型重新获取',
                                ),
                              )
                            else
                              forui.FButton(
                                variant: forui.FButtonVariant.outline,
                                mainAxisSize: MainAxisSize.min,
                                onPress: _busy ? null : _openSettings,
                                prefix: const Icon(FLucideIcons.keyRound),
                                child: const Text('配置模型'),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            for (final change in _changeItems)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '· ${change.text}',
                      style: theme.text.bodySmall,
                    ),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _undoChange(change.commitId),
                    child: const Text('撤销'),
                  ),
                ],
              ),
            if (!_independentRedo) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text('历次尝试', style: theme.text.titleSmall)),
                  if (attempts.isNotEmpty && _view?.openAttempt == null)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _startRedo,
                      prefix: const Icon(FLucideIcons.refreshCw),
                      child: const Text('再答一次（先不看上次）'),
                    ),
                ],
              ),
              if (attempts.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('提交答案后，这里会显示作答记录。'),
                ),
              for (final attempt in attempts) _attemptTile(theme, attempt),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  '独立重做：这次不显示以前的答案与帮助，提交后恢复显示。',
                  style: theme.text.bodySmall,
                ),
              ),
            if (!_independentRedo && _recentMessages.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text('同一条记录里的讨论', style: theme.text.titleSmall),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : _openDiscussion,
                    child: const Text('打开完整讨论'),
                  ),
                ],
              ),
              for (final message in _timelineMessages)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${_roleLabel(message.role)}：'
                    '${_timelineText(message)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.text.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 学习页底部只带最近三条讨论，完整历史仍打开讨论页。
  List<ChatMessage> get _timelineMessages {
    if (_recentMessages.length <= 3) return _recentMessages;
    return _recentMessages.sublist(_recentMessages.length - 3);
  }

  String _roleLabel(String role) => switch (role) {
    'user' => '你',
    'assistant' => '搭子',
    _ => '系统',
  };

  String _timelineText(ChatMessage message) {
    final text = message.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return message.hasImages ? '[图片]' : '[空消息]';
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  /// 作答草稿放在原题下面：先写几步，再点检查；提交前都可以继续改。
  Widget _draftCard(ZhixinTheme theme) {
    final helps = _view?.openAttempt?.helps.length ?? 0;
    return forui.FCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('作答草稿', style: theme.text.titleSmall)),
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
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
            const SizedBox(height: 8),
            forui.FTextField(
              control: .managed(controller: _solutionDraft),
              enabled: !_busy,
              minLines: 1,
              maxLines: 6,
              label: const Text('解法（可选）'),
              hint: '整理后单独保存，不覆盖答案、帮助与困难',
            ),
            const SizedBox(height: 10),
            Text('这次做对了吗', style: theme.text.bodyMedium),
            const SizedBox(height: 2),
            Wrap(
              spacing: 8,
              children: [
                ZhixinChip(
                  label: '做对了',
                  selected: _correct == true,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _correct = true),
                ),
                ZhixinChip(
                  label: '做错了',
                  selected: _correct == false,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _correct = false),
                ),
                ZhixinChip(
                  label: '暂不判断',
                  selected: _correct == null,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _correct = null),
                ),
              ],
            ),
            if (helps > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '本次已使用应用内帮助 $helps 次，提交后按「辅助完成」记录。',
                  style: theme.text.bodySmall,
                ),
              ),
            forui.FAccordion(
              style: const .delta(
                titlePadding: .value(EdgeInsets.symmetric(vertical: 8)),
                childPadding: .value(EdgeInsets.only(bottom: 4)),
                dividerStyle: .delta(color: Colors.transparent),
              ),
              children: [
                forui.FAccordionItem(
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('补充依据（可选）', style: theme.text.titleSmall),
                      const SizedBox(height: 2),
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
                        const SizedBox(height: 2),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            children: [
                              ZhixinChip(
                                label: '独立完成',
                                selected: _independent == true,
                                onPressed: _busy
                                    ? null
                                    : () => setState(() => _independent = true),
                              ),
                              ZhixinChip(
                                label: '用了应用外帮助',
                                selected: _independent == false,
                                onPressed: _busy
                                    ? null
                                    : () =>
                                          setState(() => _independent = false),
                              ),
                              ZhixinChip(
                                label: '未说明',
                                selected: _independent == null,
                                onPressed: _busy
                                    ? null
                                    : () => setState(() => _independent = null),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
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
    final label = attempt.submitted
        ? '${attempt.selfResult} · ${attempt.judgmentLabel}'
        : '未提交的草稿';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: forui.FCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(label, style: theme.text.labelLarge)),
                  Text(
                    attempt.submittedAt == null
                        ? ''
                        : shortTime(attempt.submittedAt!),
                    style: theme.text.bodySmall,
                  ),
                ],
              ),
              if (attempt.userAnswer != null) ...[
                const SizedBox(height: 6),
                Text('作答：${attempt.userAnswer}', style: theme.text.bodyMedium),
              ],
              if (attempt.solution?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: 6),
                Text(
                  '解法：${attempt.solution!.trim()}',
                  style: theme.text.bodyMedium,
                ),
              ],
              if (attempt.feedback?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: 6),
                Text(
                  '困难：${attempt.feedback!.trim()}',
                  style: theme.text.bodyMedium,
                ),
              ],
              if (attempt.helps.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '应用内帮助 ${attempt.helps.length} 次',
                  style: theme.text.bodySmall,
                ),
                if (attempt.helps.length <= 2 ||
                    _expandedHelps.contains(attempt.id))
                  for (final help in attempt.helps)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '· ${_helpLabel(help.kind)}：${help.content}',
                        style: theme.text.bodySmall,
                      ),
                    )
                else
                  for (final help in attempt.helps.reversed.take(2))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
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
                const SizedBox(height: 8),
                Divider(height: 1, color: theme.colors.outlineVariant),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '依据：${attempt.selfBasis}',
                    style: theme.text.bodySmall,
                  ),
                ),
                for (final assessment
                    in _assessments[attempt.id] ?? const <Assessment>[])
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
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
      await app.learningService.assessWithModel(
        questionId: widget.questionId,
        attemptId: attempt.id,
        broughtIdentities: app.broughtSources.identities,
        requestId: _requestIdForAssess(attempt.id),
      );
      app.broughtSources.clear();
      _assessRequestId = null;
      _assessRequestAttemptId = null;
      await _load();
      if (!mounted) return;
      showToast(context, '模型判断已记录');
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
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
    return cleaned.length <= limit
        ? cleaned
        : '${cleaned.substring(0, limit)}…';
  }
}
