import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../app_scope.dart';
import '../application/buddy_actions.dart';
import '../application/discussion_service.dart';
import '../application/memory_view.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/conversation.dart';
import '../domain/models/study.dart';
import 'capture_entry.dart';
import 'discussion_activity.dart';
import 'discussion_cards.dart';
import 'discussion_message.dart';
import 'failure_feedback.dart';
import 'goal_picker.dart';
import 'learning_page.dart';
import 'material_picker.dart';
import 'materials_page.dart';
import 'plan_dialogs.dart';
import 'plan_page.dart';
import 'settings_page.dart';
import 'study_plan_page.dart';
import 'undo_feedback.dart';
import 'voice_input_button.dart';
import 'workspace_widgets.dart';
import 'zhixin_chip.dart';
import 'zhixin_dialog.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 同一条讨论的聊天区：文字或图片发起、继续、接受下一步、选择归属。
///
/// 调用方必须给出 `conversationId` 或把 `startNew` 设为 true，不存在第三种状态，
/// 因此打开页面时不会悄悄接上别的讨论。
class DiscussionChat extends StatefulWidget {
  const DiscussionChat({
    super.key,
    this.conversationId,
    this.startNew = false,
    this.initialText = '',
    this.initialImages = const [],
    this.onSubmitted,
    this.emptyHint = '提出问题或添加题目图片即可开始；目标为可选项。',
  }) : assert(conversationId != null || startNew, '打开讨论要给出记录编号，或者明确说这是新讨论');

  final int? conversationId;
  final bool startNew;

  /// 首页已经取好的文字与图片：进页面时摆进输入区，等用户确认后再发送。
  final String initialText;
  final List<XFile> initialImages;

  /// 首条消息写进记录之后回调，首页用它清空已经转进讨论的草稿。
  final VoidCallback? onSubmitted;

  final String emptyHint;

  @override
  State<DiscussionChat> createState() => DiscussionChatState();
}

class DiscussionChatState extends State<DiscussionChat> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// 只让正在生成的气泡跟着正文重建，不带着整页消息一起重建。
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');

  /// 还没交给界面的最新正文：网络分片再密，一帧最多更新一次。
  String? _pendingStreamText;
  bool _streamFlushScheduled = false;

  /// 本次发送的取消信号；生成中按停止时用它中止请求。
  LlmCancelToken? _cancelToken;

  int? _conversationId;
  ConversationRecord? _record;
  List<ChatMessage> _messages = const [];
  List<PendingSuggestion> _pending = const [];
  List<MemoryItemView> _memoryItems = const [];
  List<LearningGoal> _goals = const [];
  List<AppliedChange> _changes = const [];
  List<XFile> _picked = const [];
  String? _notice;

  /// 用户消息已经落库、但这一轮没有保存回答；提示条据此给出重试入口。
  bool _retryableNotice = false;
  bool _streaming = false;
  bool _followScheduled = false;
  bool _loading = true;
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasOlderMessages = false;
  bool _answering = false;
  bool _started = false;

  /// 是否已经配置模型：决定本地规则回答下方给配置入口还是重新回答入口。
  bool _configured = false;

  /// 正在用模型重答上一条问题；与首次发送共用输入框的停止按钮。
  bool _retrying = false;

  /// 取图与框选是一段异步流程，期间再点一次会同时开两个相机。
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _streamingText.addListener(_onStreamingTextChanged);
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _conversationId = widget.conversationId;
    _initialize();
  }

  Future<void> _initialize() async {
    _input.text = widget.initialText;
    await _load();
    if (!mounted) return;
    if (widget.initialImages.isNotEmpty) {
      // 图片已经在首页取好并框过，这里只摆进输入区；文字与图片由用户确认后再发。
      setState(() => _picked = [...widget.initialImages]);
    } else if (widget.initialText.trim().isNotEmpty) {
      await _send();
    }
  }

  @override
  void dispose() {
    _streamingText.removeListener(_onStreamingTextChanged);
    _scroll.removeListener(_onScroll);
    _streamingText.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 页面重新变为可见时刷新记录，保留还没有发送的文字。
  Future<void> reload() => _load();

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      final id = _conversationId;
      // 目标、模型配置与记录互不依赖，同时读取。
      final (goals, config, record) = await (
        scope.discussionService.activeGoals(),
        scope.settingsService.config(),
        id == null
            ? Future<ConversationRecord?>.value()
            : scope.discussionService.byId(id),
      ).wait;
      final page = record == null
          ? (messages: const <ChatMessage>[], hasOlder: false)
          : await scope.discussionService.historyPage(record.id);
      final messages = page.messages;
      if (!mounted) return;
      // 消息列表决定首屏，先把它交出去；改动建议与记忆卡片随后补上，不跟着
      // 一起等待。结果回来时若还在推入动画里，等动画结束再填。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _goals = goals;
        _record = record;
        _conversationId = record?.id;
        _messages = messages;
        _hasOlderMessages = page.hasOlder;
        _pending = DiscussionService.pendingSuggestions(messages);
        _configured = config?.isConfigured ?? false;
        _loading = false;
      });
      _jumpToEnd();
      final (changes, memoryItems) = await (
        scope.discussionService.changesFromMessages(messages),
        scope.discussionService.memoryItemsFromMessages(messages),
      ).wait;
      if (!mounted) return;
      setState(() {
        _memoryItems = memoryItems;
        _changes = changes;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取这条讨论',
          kind: 'discussion_read',
          kept: '已经保存的消息没有改动',
          next: '可以返回记录页再打开',
        );
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients ||
        _loadingOlder ||
        !_hasOlderMessages ||
        _scroll.position.pixels < _scroll.position.maxScrollExtent - 48) {
      return;
    }
    _loadOlder();
  }

  Future<void> _loadOlder() async {
    final id = _conversationId;
    if (id == null ||
        _loadingOlder ||
        !_hasOlderMessages ||
        _messages.isEmpty) {
      return;
    }
    final beforeId = _messages.first.id;
    final oldOffset = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    setState(() => _loadingOlder = true);
    try {
      final scope = AppScope.of(context);
      final page = await scope.discussionService.historyPage(
        id,
        beforeMessageId: beforeId,
      );
      final merged = [...page.messages, ..._messages];
      final (memoryItems, changes) = await (
        scope.discussionService.memoryItemsFromMessages(merged),
        scope.discussionService.changesFromMessages(merged),
      ).wait;
      if (!mounted) return;
      setState(() {
        _messages = merged;
        _hasOlderMessages = page.hasOlder;
        _pending = DiscussionService.pendingSuggestions(merged);
        _memoryItems = memoryItems;
        _changes = changes;
        _loadingOlder = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(
          oldOffset.clamp(0.0, _scroll.position.maxScrollExtent).toDouble(),
        );
      });
    } catch (error, stack) {
      if (mounted) {
        setState(() {
          _loadingOlder = false;
          _notice = describeFailure(
            context,
            error,
            stack,
            action: '读取较早讨论',
            kind: 'discussion_read_older',
            kept: '已经看到的消息保持不变',
            next: '可以再点一次读取较早讨论',
          );
        });
      }
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 流式正文变化时只排一次贴底，不跟着每个网络分片重复排队。
  void _onStreamingTextChanged() {
    if (!mounted || !_streaming || !_isNearBottom || _followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_streaming || !_scroll.hasClients || !_isNearBottom) {
        return;
      }
      _scroll.jumpTo(0);
    });
  }

  void _showUserMessage(ChatMessage message) {
    if (!mounted || _messages.any((item) => item.id == message.id)) return;
    _streamingText.value = '';
    _pendingStreamText = null;
    setState(() {
      _messages = [..._messages, message];
      _streaming = true;
    });
    // 发送后直接贴到底部，第一段正文出现时不用等滚动动画。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(0);
    });
  }

  /// 流式正文按帧合并：一帧里来多少分片，正文都只重排一次。
  ///
  /// 长回答每次更新都要重新解析并排版整段 Markdown，分片越密越贵；合并之后
  /// 正文每帧最多换一次，肉眼分辨不出，长回答末尾的贴底滚动也不再发涩。
  /// 没有别的绘制要跑时先给自己排一帧，正文不会因为等不到帧卡住。
  void _showPartial(String text) {
    if (!mounted || !_streaming) return;
    _pendingStreamText = text;
    if (_streamFlushScheduled) return;
    _streamFlushScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _streamFlushScheduled = false;
      _flushStreamText();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 把攒下的最新正文交给界面；生成已经结束时丢掉，不覆盖收尾后的状态。
  void _flushStreamText() {
    final pending = _pendingStreamText;
    _pendingStreamText = null;
    if (!mounted || !_streaming || pending == null) return;
    _streamingText.value = pending;
  }

  /// 一次回答写回后的收尾：消息、建议、记忆卡片与提示一起更新。
  ///
  /// 发送与重答原先各写一段相同的合并、贴底与状态复位，改动其中一处时另一处
  /// 仍在旧写法上；现在两条路径只在取回答之前不同，写回之后走这里。
  void _settleReply(
    List<ChatMessage> merged,
    List<MemoryItemView> memoryItems,
    String? notice,
  ) {
    final followReply = _isNearBottom;
    _streamingText.value = '';
    _pendingStreamText = null;
    setState(() {
      _messages = merged;
      _pending = DiscussionService.pendingSuggestions(merged);
      _memoryItems = memoryItems;
      _notice = notice;
      _retryableNotice = false;
      _streaming = false;
    });
    if (followReply) _jumpToEnd();
  }

  /// 用户往上翻着看时不再把画面拽回底部。
  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels <= 80;
  }

  /// 发送与重答共用的开头：建取消信号、清空流式正文并进入生成状态。
  ///
  /// 重答与首次发送原先各写一遍这两步，改其中一处时另一处仍按旧写法复位；
  /// 现在只在 [retrying] 上区分要复位哪个按钮。
  LlmCancelToken _beginReply({required bool retrying}) {
    final cancel = LlmCancelToken();
    _cancelToken = cancel;
    _streamingText.value = '';
    _pendingStreamText = null;
    setState(() {
      if (retrying) {
        _retrying = true;
      } else {
        _sending = true;
        _changes = const [];
      }
      _streaming = true;
      _notice = null;
      _retryableNotice = false;
    });
    return cancel;
  }

  /// 一次回答没有写回时统一收起生成状态，并说明原因。
  ///
  /// 发送失败时 [fallbackConversationId] 是已经落库的那条记录：留住编号，
  /// 重试只补回答；[retryable] 为假时不显示重试入口，因为原问题也没有保存。
  void _failReply(
    String reason, {
    int? fallbackConversationId,
    bool retryable = true,
  }) {
    if (!mounted) return;
    setState(() {
      if (fallbackConversationId != null) {
        _conversationId ??= fallbackConversationId;
      }
      _notice = reason;
      _retryableNotice = retryable;
      _streaming = false;
    });
    _streamingText.value = '';
    _pendingStreamText = null;
  }

  /// 一次回答结束后复位生成状态；取消信号与生成活动只清理这一次的。
  void _endReply(
    LlmCancelToken cancel, {
    required bool retrying,
    int? activityId,
  }) {
    if (activityId != null) DiscussionActivity.end(activityId);
    if (identical(_cancelToken, cancel)) _cancelToken = null;
    if (!mounted) return;
    setState(() {
      if (retrying) {
        _retrying = false;
      } else {
        _sending = false;
      }
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    final submittedDraft = _input.text;
    if (text.isEmpty && _picked.isEmpty) return;
    final cancel = _beginReply(retrying: false);
    int? generatingId;
    void handleUserMessage(ChatMessage message) {
      generatingId = message.conversationId;
      DiscussionActivity.begin(generatingId!);
      _showUserMessage(message);
      // 消息已经写进记录：首页可以清掉带进来的草稿，返回时不会重复。
      widget.onSubmitted?.call();
    }

    final picks = _picked;
    AppScopeState? scope;
    var paths = const <String>[];
    var sent = false;
    try {
      scope = AppScope.of(context);
      paths = await _persistPicked(scope);
      // 从查找结果带入的来源只用于这一次回答，回答保存后即清空。
      final brought = scope.broughtSources.identities;
      final result = await scope.discussionService.reply(
        conversationId: _conversationId,
        text: text,
        imagePaths: paths,
        broughtIdentities: brought,
        onUserMessage: handleUserMessage,
        onPartial: _showPartial,
        cancelToken: cancel,
      );
      sent = true;
      scope.broughtSources.clear();
      final id = result.userMessage.conversationId;
      // 用户消息可能已经由回调先放进列表；按编号去重后再补上最终两条。
      final merged = [
        for (final message in _messages)
          if (message.id != result.userMessage.id &&
              message.id != result.assistantMessage.id)
            message,
        result.userMessage,
        result.assistantMessage,
      ];
      // 记录与卡片只服务展示；读取失败不应把已经保存的回答当成发送失败，
      // 更不能在此时清理已经被消息引用的图片。
      ConversationRecord? record;
      var memoryItems = const <MemoryItemView>[];
      var notice = result.notice;
      try {
        final (loadedRecord, items) = await (
          scope.discussionService.byId(id),
          scope.discussionService.memoryItemsFromMessages(merged),
        ).wait;
        record = loadedRecord;
        memoryItems = items;
      } catch (error, stack) {
        final read = mounted
            ? describeFailure(
                context,
                error,
                stack,
                action: '读取这条讨论的记录',
                kind: 'discussion_read_after_send',
                kept: '回答已经保存',
                next: '可以返回记录页再打开',
              )
            : '读取记录没有完成，回答已经保存。';
        notice = notice == null ? read : '$notice $read';
      }
      if (!mounted) return;
      if (_input.text == submittedDraft) _input.clear();
      setState(() {
        _conversationId = id;
        _picked = const [];
        _record = record ?? _record;
      });
      _settleReply(merged, memoryItems, notice);
      // 消息已经写进库，缓存里的取图副本可以删了；发送失败时保留，用户可以再发一次。
      await deleteTemporaryCaptures(picks);
      if (!result.fromModel && (result.notice?.contains('尚未配置') ?? false)) {
        _showModelGuide();
      }
    } catch (error, stack) {
      if (!sent && scope != null && paths.isNotEmpty) {
        try {
          await scope.cleanupAttachmentPaths(paths);
        } catch (_) {
          // 后续启动仍会清理失去引用的图片；清理失败不替代发送错误。
        }
      }
      if (!mounted) return;
      final saved = generatingId != null;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '发送这条消息',
        kind: 'discussion_send',
        kept: saved ? '问题已经保存在这条讨论里' : '输入的文字和图片还在页面上',
        next: saved ? '可以点下方「重试这次回答」' : '可以再试一次',
      );
      _failReply(
        message,
        fallbackConversationId: generatingId,
        retryable: saved,
      );
    } finally {
      _endReply(cancel, retrying: false, activityId: generatingId);
    }
  }

  /// 停止本次生成；服务会把已经显示的部分保存为回答。
  void _stop() {
    _cancelToken?.cancel();
  }

  Future<List<String>> _persistPicked(AppScopeState scope) async {
    if (_picked.isEmpty) return const [];
    final paths = await persistCaptureImages(
      _picked,
      scope.paths.imagesDir,
      prefix: 'm',
    );
    if (paths.length < _picked.length && mounted) {
      setState(() => _notice = '图片保存失败，本次已改为发送文字。');
    }
    return paths;
  }

  Future<void> _pick(ImageSource source) async {
    if (_picking) return;
    if (_picked.length >= 2) {
      showToast(context, '最多添加两张图片，请先移除一张');
      return;
    }
    setState(() => _picking = true);
    try {
      final picked = await pickQuestionImage(context, source);
      if (picked != null && mounted) {
        setState(() => _picked = [..._picked, picked]);
      }
    } catch (error) {
      if (!mounted) return;
      showToast(context, captureErrorText(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  String _imagePath(String stored) =>
      AppScope.of(context).paths.resolveImage(stored);

  Future<void> _chooseAttachment() async {
    final source = await chooseCaptureSource(context);
    if (source == null || !mounted) return;
    await _pick(source);
  }

  /// 从这条讨论开始作答：以当时最后一条用户消息为原题，作答挂在这条记录上。
  Future<void> _startAnswering() async {
    final id = _conversationId;
    if (id == null || _answering) return;
    setState(() {
      _answering = true;
      _notice = null;
    });
    try {
      final questionId = await AppScope.of(context).learningService
          .startAnswering(conversationId: id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LearningPage(questionId: questionId),
        ),
      );
      if (mounted) await _load();
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '打开作答',
          kind: 'discussion_start_answer',
          kept: '讨论与作答记录没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _answering = false);
    }
  }

  Future<void> _chooseGoal() async {
    final record = _record;
    if (record == null) return;
    final choice = await showGoalChoice(
      context,
      goals: _goals,
      initialGoalId: record.goalId,
      title: '选择目标',
      note: '目标为可选项；更改归属会保留已有记录。',
    );
    if (choice == null || !mounted) return;
    final service = AppScope.of(context).discussionService;
    try {
      await service.setGoal(record.id, choice.goalId);
      final updated = await service.byId(record.id);
      if (!mounted) return;
      setState(() => _record = updated);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '修改这条讨论的目标',
          kind: 'discussion_goal',
          kept: '原来的归属没有改动',
          next: '可以重新选择一次',
        ),
      );
    }
  }

  Future<void> _chooseMaterial() async {
    final record = _record;
    if (record == null) return;
    final selection = await showMaterialPicker(
      context,
      initialMaterialId: record.materialId,
      initialPageNo: record.pageNo,
    );
    if (selection == null || !mounted) return;
    final service = AppScope.of(context).discussionService;
    try {
      await service.setMaterial(
        record.id,
        materialId: selection.materialId,
        pageNo: selection.pageNo,
      );
      final updated = await service.byId(record.id);
      if (!mounted) return;
      setState(() => _record = updated);
      showToast(context, '已使用材料：${selection.label}');
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '关联材料',
          kind: 'discussion_material',
          kept: '原来的材料没有改动',
          next: '可以重新选择一次',
        ),
      );
    }
  }

  /// 从这条讨论开始系统学习：复用同一份材料与当前页作为起点。
  Future<void> _startStudyPlan() async {
    final record = _record;
    final materialId = record?.materialId;
    if (record == null || materialId == null) return;
    final scope = AppScope.of(context);
    final material = await scope.materialService.byId(materialId);
    if (!mounted) return;
    if (material == null) {
      setState(() => _notice = '未找到这份材料');
      return;
    }
    await showStudyPlanSetup(
      context,
      material: material,
      conversationId: record.id,
      initialPage: record.pageNo ?? 1,
    );
  }

  Future<void> _accept(
    PendingSuggestion suggestion, {
    bool schedule = false,
  }) async {
    final id = _conversationId;
    if (id == null) return;
    final choice = await showGoalChoice(
      context,
      goals: _goals,
      initialGoalId: _record?.goalId,
      title: '选择目标',
      note: '可选择目标，也可将安排单独保留。',
    );
    if (choice == null || !mounted) return;
    try {
      final scope = AppScope.of(context);
      BlockDraft? timing;
      if (schedule) {
        // 先让用户选时间；取消选时就不保存事项，避免“保存并预约”留下半个结果。
        timing = await showZhixinDialog<BlockDraft>(
          context: context,
          builder: (_) => BlockDialog(
            items: [PlanItem(id: 0, title: suggestion.draft.title)],
            initialMinutes: suggestion.draft.minutes,
          ),
        );
        if (timing == null || !mounted) return;
      }
      final result = await scope.discussionService.acceptNextStep(
        conversationId: id,
        messageId: suggestion.messageId,
        draft: suggestion.draft,
        stepId: suggestion.stepId,
        goalId: choice.goalId,
        requestId: 'accept-step-${suggestion.messageId}-${suggestion.stepId}',
      );
      if (!mounted) return;
      var scheduled = false;
      var scheduledCommitId = 0;
      if (timing != null) {
        try {
          scheduledCommitId = await scope.planService.scheduleItem(
            planItemId: result.item.id,
            start: timing.start,
            end: timing.start.add(Duration(minutes: timing.minutes)),
            source: 'ai',
          );
          scheduled = true;
        } catch (error, stack) {
          if (mounted) {
            setState(
              () => _notice = describeFailure(
                context,
                error,
                stack,
                action: '保存预约时间',
                kind: 'discussion_schedule',
                kept: '学习事项已经保存',
                next: '可以点「查看并安排」再选时间',
              ),
            );
          }
        }
      }
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      final message = scheduled
          ? '已保存并预约时间'
          : schedule
          ? '已保存为学习事项，尚未预约时间'
          : '已保存为学习事项';
      showActionToast(
        context,
        message,
        label: scheduled ? '撤销预约' : '查看并安排',
        onPressed: scheduled
            ? () => undoCommitWithFeedback(
                context,
                scheduledCommitId,
                reload: _load,
              )
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlanPage(initialItemId: result.item.id),
                ),
              ),
      );
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存这条学习安排',
          kind: 'discussion_accept_step',
          kept: '建议还在讨论里',
          next: '可以再试一次',
        ),
      );
    }
  }

  Future<void> _dismiss(PendingSuggestion suggestion) async {
    final id = _conversationId;
    if (id == null) return;
    try {
      await AppScope.of(context).discussionService.dismissNextStep(
        conversationId: id,
        messageId: suggestion.messageId,
        title: suggestion.draft.title,
        stepId: suggestion.stepId,
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '收起这条建议',
          kind: 'discussion_dismiss_step',
          kept: '建议还在讨论里',
          next: '可以再试一次',
        ),
      );
    }
  }

  Future<void> _undoChange(AppliedChange change) =>
      undoCommitWithFeedback(context, change.commitId, reload: _load);

  Future<void> _acceptMemory(MemoryItemView item) async {
    final id = _conversationId;
    if (id == null) return;
    try {
      final result = await AppScope.of(context).discussionService
          .acceptMemoryItem(
            conversationId: id,
            messageId: item.ownerId,
            itemId: item.itemId,
          );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      showToast(context, result.notice ?? '已记下这条记忆');
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存这条记忆',
          kind: 'discussion_memory_accept',
          kept: '这条记忆仍在待确认',
          next: '可以再点一次「记下」',
        ),
      );
    }
  }

  Future<void> _dismissMemory(MemoryItemView item) async {
    final id = _conversationId;
    if (id == null) return;
    try {
      await AppScope.of(context).discussionService.dismissMemoryItem(
        conversationId: id,
        messageId: item.ownerId,
        itemId: item.itemId,
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '收起这条记忆',
          kind: 'discussion_memory_dismiss',
          kept: '记忆卡片还在页面上',
          next: '可以再试一次',
        ),
      );
    }
  }

  Future<void> _undoMemory(MemoryItemView item) async {
    final commitId = item.commitId;
    if (commitId == null) return;
    await _undoChange(
      AppliedChange(
        commitId: commitId,
        text: '已添加记忆：${item.draft.kind.label} · ${item.draft.content}',
      ),
    );
  }

  /// 只改记录状态，不离开页面；发消息会重新打开。
  Future<void> _end() async {
    final id = _conversationId;
    final record = _record;
    if (id == null || record == null || !record.open) return;
    final service = AppScope.of(context).discussionService;
    try {
      await service.end(id);
      if (!mounted) return;
      final updated = await service.byId(id);
      if (!mounted) return;
      setState(() => _record = updated);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '结束这条讨论',
          kind: 'discussion_end',
          kept: '讨论仍是进行中',
          next: '可以再试一次',
        ),
      );
    }
  }

  /// 未配置时的提示条：给出配置入口，配置完成后卡片上会多出重新回答的按钮。
  void _showModelGuide() {
    if (!mounted) return;
    showActionToast(
      context,
      '当前使用本地规则回答；配置模型后可以重新回答这个问题。',
      label: '配置模型',
      onPressed: _openModelSettings,
    );
  }

  /// 打开设置页并重新读取配置；返回后卡片上的入口随之切换。
  Future<void> _openModelSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    if (!mounted) return;
    await _reloadConfig();
    if (!mounted) return;
    showToast(
      context,
      _configured ? '模型已就绪，可以重新回答上面这个问题。' : '模型还没有配置完整，仍使用本地规则回答。',
    );
  }

  Future<void> _reloadConfig() async {
    try {
      final config = await AppScope.of(context).settingsService.config();
      if (mounted) setState(() => _configured = config?.isConfigured ?? false);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取模型配置',
          kind: 'discussion_config_read',
          kept: '这条讨论没有改动',
          next: '可以回到设置页重新保存一次',
        ),
      );
    }
  }

  /// 用模型重答最后一个问题：不重复写用户消息，新回答追加在后面。
  Future<void> _retry() async {
    final id = _conversationId;
    if (id == null || _sending || _retrying) return;
    final cancel = _beginReply(retrying: true);
    DiscussionActivity.begin(id);
    try {
      final result = await AppScope.of(context).discussionService.reply(
        conversationId: id,
        repeatLast: true,
        onPartial: _showPartial,
        cancelToken: cancel,
      );
      if (!mounted) return;
      final merged = [
        for (final message in _messages)
          if (message.id != result.assistantMessage.id) message,
        result.assistantMessage,
      ];
      var memoryItems = _memoryItems;
      try {
        memoryItems = await AppScope.of(context).discussionService
            .memoryItemsFromMessages(merged);
      } catch (_) {
        // 卡片只是展示；读不出来不影响已经保存的回答。
      }
      if (!mounted) return;
      _settleReply(merged, memoryItems, result.notice);
    } on LlmException catch (error) {
      final next = switch (error.failure) {
        LlmFailure.notConfigured => '先到设置里配置模型后再试',
        LlmFailure.auth => '请检查设置里的 API Key 与模型名后再试',
        _ => '可以点下方重试',
      };
      _failReply('重新回答失败（${error.shortText}）；原来的问题与回答没有改动，$next。');
    } catch (error, stack) {
      if (!mounted) return;
      _failReply(
        describeFailure(
          context,
          error,
          stack,
          action: '重新回答',
          kind: 'discussion_retry',
          kept: '原来的问题与回答没有改动',
          next: '可以点下方重试',
        ),
      );
    } finally {
      _endReply(cancel, retrying: true, activityId: id);
    }
  }

  /// 回答下方唯一的恢复入口：只挂在最后一条回答上。
  ///
  /// 没配模型时给配置入口；配好之后，本地规则回答给「用模型重新回答」，
  /// 模型失败或生成中断的回答给「重试这次回答」。失败说明随回答保存在消息里，
  /// 重新打开讨论后仍在这一条回答下方，不只是一次性提示。
  Widget? _localFooter(int index) {
    if (index != _messages.length - 1) return null;
    final message = _messages[index];
    if (message.role != 'assistant') return null;
    final structured = message.structured;
    final fromModel = structured?['model'] == true;
    final interrupted = message.interrupted;
    if (fromModel && !interrupted) return null;
    final failed = structured?['model_failed'] == true;
    final label = failed || interrupted ? '重试这次回答' : '用模型重新回答';
    final savedNotice = structured?['failure_notice']?.toString().trim();
    final failureNotice = savedNotice == null || savedNotice.isEmpty
        ? null
        : savedNotice;
    final failure = structured?['model_failure']?.toString();
    final needsConfig =
        failure == 'auth' ||
        failure == 'badResponse' ||
        failure == 'toolUnsupported' ||
        failure == 'rateLimited' ||
        failure == 'unknown' ||
        (failure == null && (failureNotice?.contains('配置') ?? false));
    final theme = context.zhixin;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 发送后提示条已经显示同一句时不再重复；重新打开讨论时只在这里显示。
          if (failureNotice != null && failureNotice != _notice)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(failureNotice, style: theme.text.bodySmall),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_configured)
                forui.FButton(
                  variant: forui.FButtonVariant.secondary,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _sending || _retrying ? null : _retry,
                  prefix: const Icon(FLucideIcons.refreshCw),
                  child: Text(label),
                )
              else
                forui.FButton(
                  variant: forui.FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _sending || _retrying ? null : _openModelSettings,
                  prefix: const Icon(FLucideIcons.keyRound),
                  child: const Text('配置模型'),
                ),
              if (_configured && needsConfig)
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _sending || _retrying ? null : _openModelSettings,
                  prefix: const Icon(FLucideIcons.settings),
                  child: const Text('模型设置'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: forui.FCircularProgress());
    }
    final theme = context.zhixin;
    return Column(
      children: [
        if (_record != null) _recordBar(theme, _record!),
        Expanded(
          child: _emptyTimeline
              ? Center(
                  child: EmptyState(
                    icon: FLucideIcons.messageCircle,
                    title: '讨论内容',
                    description: widget.emptyHint,
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  // 倒序列表把最新一条放在偏移 0，打开长讨论时直接落在底部。
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: _timelineCount + (_hasOlderMessages ? 1 : 0),
                  itemBuilder: (context, index) =>
                      index == _timelineCount && _hasOlderMessages
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _loadingOlder
                                ? const forui.FCircularProgress(size: .sm)
                                : forui.FButton(
                                    variant: forui.FButtonVariant.ghost,
                                    mainAxisSize: MainAxisSize.min,
                                    onPress: _loadOlder,
                                    child: const Text('读取较早讨论'),
                                  ),
                          ),
                        )
                      : _timelineItem(theme, _timelineCount - 1 - index),
                ),
        ),
        _composer(),
      ],
    );
  }

  Widget _recordBar(ZhixinTheme theme, ConversationRecord record) {
    final goal = record.goalId == null
        ? null
        : _goals.where((item) => item.id == record.goalId).firstOrNull;
    return Container(
      width: double.infinity,
      padding: theme.space.pageInsets(
        top: theme.space.xs,
        bottom: theme.space.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colors.outlineVariant)),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ZhixinChip(
            icon: FLucideIcons.flag,
            label: goal?.title ?? '选择目标',
            onPressed: _sending ? null : _chooseGoal,
          ),
          ZhixinChip(
            icon: FLucideIcons.bookOpen,
            label: record.hasMaterial ? record.materialLabel : '选择材料',
            onPressed: _sending ? null : _chooseMaterial,
          ),
          if (record.hasMaterial) ...[
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => _showSource(record),
              prefix: const Icon(FLucideIcons.newspaper),
              child: const Text('查看原文'),
            ),
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _sending ? null : _startStudyPlan,
              prefix: const Icon(FLucideIcons.route),
              child: const Text('系统学习'),
            ),
          ],
          if (_messages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: forui.FButton(
                variant: forui.FButtonVariant.secondary,
                mainAxisSize: MainAxisSize.min,
                onPress: _sending || _answering ? null : _startAnswering,
                prefix: _answering
                    ? const forui.FCircularProgress(
                        size: forui.FCircularProgressSizeVariant.sm,
                      )
                    : const Icon(FLucideIcons.notebookPen),
                child: Text(record.hasAttempts ? '继续作答' : '开始作答'),
              ),
            ),
          if (record.open)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _sending ? null : _end,
              child: const Text('结束讨论'),
            )
          else
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: StatusTag(
                '已结束',
                tone: TagTone.muted,
                icon: FLucideIcons.circleCheck,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showSource(ConversationRecord record) async {
    try {
      final pageNo = record.pageNo;
      final page = pageNo == null
          ? null
          : await AppScope.of(context).materialService
                .page(record.materialId!, pageNo);
      if (!mounted) return;
      await showZhixinSheet<void>(
        context: context,
        builder: (sheetContext) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.7,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                record.materialLabel,
                style: context.zhixin.text.titleMedium,
              ),
              const SizedBox(height: 16),
              SelectableText(page?.content ?? '当前页暂无原文。补充原文后，可在此查看。'),
              const SizedBox(height: 16),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          MaterialDetailPage(materialId: record.materialId!),
                    ),
                  );
                },
                child: const Text('打开完整材料'),
              ),
            ],
          ),
        ),
      );
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取材料原文',
        kind: 'discussion_source_read',
        kept: '讨论记录没有改动',
        next: '可以再打开一次',
      );
      showToast(context, message);
    }
  }

  bool get _emptyTimeline =>
      _messages.isEmpty &&
      !_streaming &&
      _memoryItems.isEmpty &&
      _pending.isEmpty &&
      _changes.isEmpty &&
      _notice == null;

  /// 消息、正在生成的回答、记忆卡片、建议、回执与说明排成同一列。
  int get _timelineCount {
    var count = _messages.isEmpty && !_streaming
        ? 1
        : _messages.length + (_streaming ? 1 : 0);
    count += _memoryItems.length;
    count += _pending.length;
    if (_changes.isNotEmpty) count++;
    if (_notice != null) count++;
    return count;
  }

  Widget _timelineItem(ZhixinTheme theme, int index) {
    var cursor = index;
    if (_messages.isEmpty && !_streaming) {
      if (cursor == 0) {
        return Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            widget.emptyHint,
            textAlign: TextAlign.center,
            style: theme.text.bodyMedium,
          ),
        );
      }
      cursor--;
    } else {
      if (cursor < _messages.length) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DiscussionMessage(
            message: _messages[cursor],
            imagePath: _imagePath,
            footer: _localFooter(cursor),
            onOpenCitation: (citation) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MaterialDetailPage(
                  materialId: citation.materialId,
                  pageFrom: citation.pageNo,
                  pageTo: citation.pageNo,
                  stepTitle: '引用原文',
                ),
              ),
            ),
          ),
        );
      }
      cursor -= _messages.length;

      if (_streaming) {
        if (cursor == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<String>(
              valueListenable: _streamingText,
              builder: (context, text, _) => StreamingMessage(text: text),
            ),
          );
        }
        cursor--;
      }
    }

    if (cursor < _memoryItems.length) {
      final item = _memoryItems[cursor];
      return MemoryCard(
        item: item,
        onAccept: () => _acceptMemory(item),
        onDismiss: () => _dismissMemory(item),
        onUndo: () => _undoMemory(item),
      );
    }
    cursor -= _memoryItems.length;

    if (cursor < _pending.length) {
      final suggestion = _pending[cursor];
      return SuggestionCard(
        suggestion: suggestion,
        onAccept: () => _accept(suggestion),
        onSchedule: () => _accept(suggestion, schedule: true),
        onDismiss: () => _dismiss(suggestion),
      );
    }
    cursor -= _pending.length;

    if (_changes.isNotEmpty) {
      if (cursor == 0) {
        return ChangeReceiptCard(changes: _changes, onUndo: _undoChange);
      }
      cursor--;
    }

    if (_notice != null && cursor == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  FLucideIcons.info,
                  size: 16,
                  color: theme.colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_notice!, style: theme.text.bodySmall),
                      if (_retryableNotice && !_streaming)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: forui.FButton(
                            variant: forui.FButtonVariant.ghost,
                            mainAxisSize: MainAxisSize.min,
                            onPress: _retrying ? null : _retry,
                            prefix: const Icon(FLucideIcons.refreshCw),
                            child: const Text('重试这次回答'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _composer() {
    final theme = context.zhixin;
    return SafeArea(
      top: false,
      child: Container(
        margin: theme.space.pageInsets(
          top: theme.space.xs,
          bottom: theme.space.sm,
        ),
        padding: EdgeInsets.all(theme.space.sm),
        decoration: BoxDecoration(
          color: theme.colors.card,
          border: Border.all(color: theme.colors.outlineVariant),
          borderRadius: theme.radius.feature,
        ),
        child: Column(
          children: [
            if (AppScope.of(context).broughtSources.length > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                      FLucideIcons.listChecks,
                      size: 16,
                      color: context.zhixin.colors.primary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '已加入 '
                        '${AppScope.of(context).broughtSources.length} 条来源，'
                        '发送后清除。',
                        style: context.zhixin.text.bodySmall,
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
              ),
            if (_picked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: CapturePhotoStrip(
                  photos: _picked,
                  onRemove: (index) => setState(
                    () => _picked = [
                      for (var i = 0; i < _picked.length; i++)
                        if (i != index) _picked[i],
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                ZhixinIconButton(
                  tooltip: '添加图片',
                  variant: forui.FButtonVariant.secondary,
                  onPressed: _sending || _picking ? null : _chooseAttachment,
                  icon: FLucideIcons.imagePlus,
                ),
                SizedBox(width: theme.space.sm),
                Expanded(
                  child: forui.FTextField(
                    control: .managed(controller: _input),
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    hint: _record?.open == false
                        ? '这条讨论已结束，发消息会重新打开'
                        : '输入问题或添加图片',
                    style: .delta(
                      border: .delta([.all(InputBorder.none)]),
                      color: .delta([.all(Colors.transparent)]),
                    ),
                    suffixBuilder: (_, style, _) => VoiceInputButton(
                      controller: _input,
                      iconSize: 20,
                      style: style.clearButtonStyle.copyWith(
                        iconContentStyle: const .delta(
                          constraints: BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ZhixinIconButton(
                  tooltip: _sending ? '停止生成' : '发送',
                  variant: forui.FButtonVariant.primary,
                  size: forui.FButtonSizeVariant.lg,
                  iconSize: _sending ? 18 : 22,
                  onPressed: _sending ? _stop : _send,
                  icon: _sending ? FLucideIcons.square : FLucideIcons.arrowUp,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
