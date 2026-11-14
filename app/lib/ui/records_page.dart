import 'package:flutter/foundation.dart';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/assessment.dart';
import '../domain/models/conversation.dart';
import '../domain/models/question.dart';
import '../domain/models/study.dart';
import 'discussion_activity.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'materials_page.dart';
import 'question_capture_button.dart';
import 'embedding_settings_page.dart';
import 'records_search_page.dart';
import 'workspace_widgets.dart';
import 'zhixin_chip.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_segmented.dart';
import 'zhixin_toast.dart';

enum RecordsTab { learning, materials }

/// 从别的栏目跳到记录时的意图：切到哪个页签，以及这是第几次请求。
///
/// 三栏页面常驻、只建一次，跳转不再改构造参数，改用这个请求通知页面。
class RecordsRequest {
  const RecordsRequest(this.tab, this.sequence);

  final RecordsTab tab;

  /// 每次跳转加一；页面据此判断是不是新的一次请求。
  final int sequence;
}

/// 记录：按日期找回学习记录，也可以查看材料原文。
class RecordsPage extends StatefulWidget {
  const RecordsPage({
    super.key,
    required this.activeTab,
    this.tabIndex = 1,
    required this.request,
    required this.onOpenLearning,
    required this.onOpenDiscussion,
    this.onOpenLearningRedo,
    this.onStartQuestion,
  });

  /// 底栏当前栏的下标；页面自己监听，父级切栏时不再重建这一栏。
  final ValueListenable<int> activeTab;
  final int tabIndex;

  /// 从别的栏目跳到记录时带的意图：切到哪个页签，第几次请求。
  final ValueListenable<RecordsRequest> request;
  final VoidCallback? onStartQuestion;
  final Future<void> Function(int questionId) onOpenLearning;
  final Future<void> Function(int conversationId) onOpenDiscussion;

  /// 从记录直接进入“先不看上次”的独立重做。
  final Future<void> Function(int questionId)? onOpenLearningRedo;

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  final GlobalKey<MaterialListState> _materialsKey =
      GlobalKey<MaterialListState>();
  final TextEditingController _searchHint = TextEditingController();
  static const _answerFilters = ['wrong', 'unjudged', 'correct', 'open'];

  /// 一次读这么多条记录与对应的题目；再多由列表底部的入口继续读。
  static const _pageSize = 30;

  Map<int, QuestionRow> _questions = const {};
  Map<int, List<Assessment>> _assessments = const {};
  String? _answerFilter;
  int _loadRequest = 0;

  List<ConversationRecord> _records = const [];
  List<LearningGoal> _goals = const [];
  int? _goalFilter;
  bool _unassignedOnly = false;
  bool _hasMore = false;
  bool _loadingMore = false;
  RecordsTab _tab = RecordsTab.learning;

  /// 进过的页签常驻：切回来不再重建，也不重新读取，滚动位置一并保住。
  final Set<RecordsTab> _visited = {RecordsTab.learning};

  /// 已经处理到第几次跳转请求；用来忽略重复通知。
  int _seenRequest = 0;

  /// 数据版本在页面里监听：整库恢复之后自己重读，父级不再包一层。
  ValueListenable<int>? _dataVersion;

  /// 列表当前显示的是哪一组筛选的结果；读完新筛选之后才换，列表据此淡入，
  /// 刷新或从详情返回时筛选没变，列表不闪。
  Object? _shownFilter;
  bool _loading = true;
  bool _started = false;

  bool get _active => widget.activeTab.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    _seenRequest = widget.request.value.sequence;
    widget.activeTab.addListener(_onActiveChanged);
    widget.request.addListener(_onRequestChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    DiscussionActivity.generating.removeListener(_onGeneratingChanged);
    DiscussionActivity.generating.addListener(_onGeneratingChanged);
    _watchDataVersion(AppScope.of(context).dataVersion);
    if (_started || !_active) return;
    _started = true;
    _load();
  }

  @override
  void didUpdateWidget(covariant RecordsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTab != widget.activeTab) {
      oldWidget.activeTab.removeListener(_onActiveChanged);
      widget.activeTab.addListener(_onActiveChanged);
    }
    if (oldWidget.request != widget.request) {
      oldWidget.request.removeListener(_onRequestChanged);
      widget.request.addListener(_onRequestChanged);
    }
  }

  @override
  void dispose() {
    widget.activeTab.removeListener(_onActiveChanged);
    widget.request.removeListener(_onRequestChanged);
    _dataVersion?.removeListener(_onDataChanged);
    DiscussionActivity.generating.removeListener(_onGeneratingChanged);
    _searchHint.dispose();
    super.dispose();
  }

  /// 切到这一栏时立刻发起读取；已有内容先显示，读完静默替换。
  void _onActiveChanged() {
    if (!mounted || !_active) return;
    _started = true;
    _load();
    if (_tab == RecordsTab.materials) _materialsKey.currentState?.reload();
  }

  /// 从首页跳到“材料”或“学习记录”：只切页签，常驻内容不重读。
  void _onRequestChanged() {
    final request = widget.request.value;
    if (!mounted || request.sequence == _seenRequest) return;
    _seenRequest = request.sequence;
    setState(() {
      _tab = request.tab;
      _visited.add(request.tab);
    });
  }

  void _watchDataVersion(ValueListenable<int> version) {
    if (identical(version, _dataVersion)) return;
    _dataVersion?.removeListener(_onDataChanged);
    _dataVersion = version;
    version.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted || !_active) return;
    _load();
    if (_tab == RecordsTab.materials) _materialsKey.currentState?.reload();
  }

  /// 生成开始或结束时重画记录；消息数与摘要等下次读取列表时更新。
  void _onGeneratingChanged() {
    if (!mounted || !_active) return;
    setState(() {});
  }

  /// 打开学习页或讨论页，返回后只重读列表；三栏不随这次浏览重建。
  Future<void> _openLearning(int questionId) async {
    await widget.onOpenLearning(questionId);
    if (mounted) await _load();
  }

  Future<void> _openDiscussion(int conversationId) async {
    await widget.onOpenDiscussion(conversationId);
    if (mounted) await _load();
  }

  Future<void> _openLearningRedo(int questionId) async {
    final open = widget.onOpenLearningRedo;
    if (open == null) {
      await _openLearning(questionId);
      return;
    }
    await open(questionId);
    if (mounted) await _load();
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordsSearchPage(
          onOpenLearning: _openLearning,
          onOpenDiscussion: _openDiscussion,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _load() => _read(append: false);

  /// 继续读下一页；筛选条件与排序键不变，不会重复或漏掉记录。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    await _read(append: true);
  }

  /// 只读当前这一页的记录，题目视图也限制在这一页里。
  ///
  /// 筛选与分页都交给查询，界面不再先把整库记录读回来再逐条比较；[append]
  /// 为真时接着上一页读，返回的记录追加在后面。
  Future<void> _read({required bool append}) async {
    if (!mounted) return;
    _started = true;
    final scope = AppScope.of(context);
    final request = ++_loadRequest;
    final filter = (_goalFilter, _unassignedOnly, _answerFilter);
    if (append) setState(() => _loadingMore = true);
    try {
      // 目标列表与这一页记录互不依赖，同时发出，首屏少一次往返。
      final (goals, records) = await (
        append
            ? Future<List<LearningGoal>>.value(_goals)
            : scope.chat.discussion.goals(),
        scope.chat.discussion.records(
          goalId: _unassignedOnly ? null : _goalFilter,
          unassignedOnly: _unassignedOnly,
          answerStatus: _answerFilter,
          limit: _pageSize,
          offset: append ? _records.length : 0,
        ),
      ).wait;
      final questions = records.isEmpty
          ? const <QuestionRow>[]
          : await scope.conversations.questionRows(
              conversationIds: records.map((record) => record.id),
            );
      final lastAttempts = [
        for (final row in questions)
          if (row.lastAttempt != null) row.lastAttempt!,
      ];
      final assessments = lastAttempts.isEmpty
          ? const <int, List<Assessment>>{}
          : await scope.chat.learning.assessmentsFor(lastAttempts);
      if (!mounted || request != _loadRequest) return;
      // 结果回来时若还在切栏或返回动画里，等动画走完再填，回填不打断动画。
      await context.afterTransition();
      if (!mounted || request != _loadRequest) return;
      final loaded = <int, QuestionRow>{if (append) ..._questions};
      for (final row in questions) {
        loaded[row.question.id] = row;
      }
      final loadedAssessments = <int, List<Assessment>>{
        if (append) ..._assessments,
        ...assessments,
      };
      setState(() {
        _goals = goals;
        _records = append ? [..._records, ...records] : records;
        _questions = loaded;
        _assessments = loadedAssessments;
        _hasMore = records.length == _pageSize;
        _loadingMore = false;
        _loading = false;
        if (!append) _shownFilter = filter;
      });
    } catch (error, stack) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取学习记录',
        kind: 'records_read',
        kept: '当前筛选和已经读出的内容保持不变',
        next: '可以点右上角刷新再试',
      );
      showToast(context, message);
    }
  }

  String _goalLabel(int? goalId) {
    if (goalId == null) return '无归属';
    return _goals.where((goal) => goal.id == goalId).firstOrNull?.title ??
        '目标已删除';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final learning = _tab == RecordsTab.learning;
    return TabScaffold(
      header: ZhixinHeader(
        nested: false,
        title: const Text('记录'),
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.network,
            tooltip: '语义索引',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EmbeddingSettingsPage(),
              ),
            ),
          ),
          ZhixinHeaderAction(
            icon: FLucideIcons.refreshCw,
            tooltip: '刷新记录',
            onPressed: () {
              if (_tab == RecordsTab.materials) {
                _materialsKey.currentState?.reload();
              } else {
                _load();
              }
            },
          ),
        ],
      ),
      child: PageWidth(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.page,
                theme.space.xs,
                theme.space.page,
                theme.space.md,
              ),
              // 录入题目只属于学习记录，与搜索并排；筛选因此能独占一整行。
              child: Row(
                children: [
                  Expanded(
                    child: forui.FTextField(
                      key: const ValueKey('records-search-entry'),
                      control: .managed(controller: _searchHint),
                      readOnly: true,
                      onTap: _openSearch,
                      prefixBuilder: (context, style, variants) =>
                          forui.FTextField.prefixIconBuilder(
                            context,
                            style,
                            variants,
                            const Icon(FLucideIcons.search, size: 16),
                          ),
                      hint: '搜索讨论、题目或材料原文',
                    ),
                  ),
                  if (learning) ...[
                    SizedBox(width: theme.space.sm),
                    QuestionCaptureButton(
                      onOpenLearning: _openLearning,
                      onOpenDiscussion: _openDiscussion,
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: theme.space.page),
              child: ZhixinSegmented<RecordsTab>(
                segments: const [
                  ZhixinSegment(
                    value: RecordsTab.learning,
                    label: '学习记录',
                    icon: FLucideIcons.history,
                  ),
                  ZhixinSegment(
                    value: RecordsTab.materials,
                    label: '材料',
                    icon: FLucideIcons.bookOpen,
                  ),
                ],
                selected: _tab,
                onChanged: (tab) => setState(() {
                  _tab = tab;
                  _visited.add(tab);
                }),
              ),
            ),
            SizedBox(height: theme.space.sm),
            Expanded(
              // 两个页签常驻，切换只换显示：材料列表的滚动位置与已经读到的
              // 数据都留住，切回来不再整棵重建、不再重读。首次进入某页签时
              // 才把它建出来。换页签与读完第一页时，新内容淡入一次。
              child: FadeIn.withTransition(
                trigger: (_tab, learning && _loading),
                playOnInit: false,
                builder: (transition) => IndexedStack(
                  sizing: StackFit.expand,
                  index: learning ? 0 : 1,
                  children: [
                    _learningRecords(theme),
                    if (_visited.contains(RecordsTab.materials))
                      MaterialList(
                        key: _materialsKey,
                        tabTransition: transition,
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _filtered =>
      _goalFilter != null || _unassignedOnly || _answerFilter != null;

  void _setGoalFilter({int? goalId, bool unassigned = false}) {
    setState(() {
      _goalFilter = unassigned ? null : goalId;
      _unassignedOnly = unassigned;
    });
    _load();
  }

  void _setAnswerFilter(String? status) {
    setState(() => _answerFilter = status);
    _load();
  }

  /// 筛选只占一行：作答状态的下拉放在最前，目标归属的选项跟在后面横向滚动。
  Widget _filterBar(ZhixinTheme theme) {
    final answerActive = _answerFilter != null;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(
          theme.space.page,
          theme.space.xs,
          theme.space.sm,
          theme.space.xs,
        ),
        child: Row(
          children: [
            ZhixinMenu(
              key: const ValueKey('records-answer-filter'),
              semanticsLabel: '筛选作答状态',
              menuAnchor: AlignmentDirectional.topStart,
              childAnchor: AlignmentDirectional.bottomStart,
              items: [
                ZhixinMenuItem(
                  label: '全部记录',
                  selected: _answerFilter == null,
                  onSelected: () => _setAnswerFilter(null),
                ),
                for (final status in _answerFilters)
                  ZhixinMenuItem(
                    label: statusLabel(status),
                    selected: _answerFilter == status,
                    onSelected: () => _setAnswerFilter(status),
                  ),
              ],
              triggerBuilder: (context, controller) => forui.FButton(
                variant: answerActive
                    ? forui.FButtonVariant.secondary
                    : forui.FButtonVariant.outline,
                size: forui.FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: controller.toggle,
                suffix: const Icon(FLucideIcons.chevronDown),
                child: Text(
                  answerActive ? statusLabel(_answerFilter!) : '作答状态',
                ),
              ),
            ),
            Container(
              width: 1,
              height: 24,
              margin: EdgeInsets.symmetric(horizontal: theme.space.sm),
              color: theme.colors.outlineVariant,
            ),
            Padding(
              padding: EdgeInsets.only(right: theme.space.sm - 2),
              child: ZhixinChip(
                label: '全部',
                size: forui.FButtonSizeVariant.sm,
                selected: _goalFilter == null && !_unassignedOnly,
                onPressed: () => _setGoalFilter(),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(right: theme.space.sm - 2),
              child: ZhixinChip(
                label: '无归属',
                size: forui.FButtonSizeVariant.sm,
                selected: _unassignedOnly,
                onPressed: () => _setGoalFilter(unassigned: true),
              ),
            ),
            for (final goal in _goals)
              Padding(
                padding: EdgeInsets.only(right: theme.space.sm - 2),
                child: ZhixinChip(
                  label: goal.title,
                  size: forui.FButtonSizeVariant.sm,
                  icon: FLucideIcons.flag,
                  selected: !_unassignedOnly && _goalFilter == goal.id,
                  onPressed: () => _setGoalFilter(goalId: goal.id),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _learningRecords(ZhixinTheme theme) {
    final records = _records;
    return Column(
      children: [
        // 筛选条不依赖读取结果，首读时就位，读完只在下面换内容，页面不往下跳。
        _filterBar(theme),
        Expanded(
          child: _loading
              // 首读用与记录卡片同高的静态骨架，读完原位替换。
              ? ListSkeleton(
                  rows: 3,
                  padding: EdgeInsets.fromLTRB(
                    theme.space.page,
                    theme.space.sm,
                    theme.space.page,
                    0,
                  ),
                )
              : FadeIn(
                  trigger: _shownFilter,
                  playOnInit: false,
                  child: records.isEmpty
                      ? SingleChildScrollView(
                          child: EmptyState(
                            icon: _filtered
                                ? FLucideIcons.filterX
                                : FLucideIcons.messageCircle,
                            title: _filtered ? '没有符合筛选的记录' : '暂无学习记录',
                            description: _filtered
                                ? '可以调整筛选条件，查看其他记录。'
                                : '讨论和题目的作答都会保存在这里。',
                            action: _filtered
                                ? forui.FButton(
                                    variant: forui.FButtonVariant.outline,
                                    mainAxisSize: MainAxisSize.min,
                                    onPress: () {
                                      setState(() {
                                        _goalFilter = null;
                                        _unassignedOnly = false;
                                        _answerFilter = null;
                                      });
                                      _load();
                                    },
                                    child: const Text('清除筛选'),
                                  )
                                : forui.FButton(
                                    variant: forui.FButtonVariant.secondary,
                                    mainAxisSize: MainAxisSize.min,
                                    onPress: widget.onStartQuestion,
                                    child: const Text('提出问题'),
                                  ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: _recordList(theme, records),
                        ),
                ),
        ),
      ],
    );
  }

  Widget _recordList(ZhixinTheme theme, Iterable<ConversationRecord> records) {
    final groups = <String, List<ConversationRecord>>{};
    for (final record in records) {
      final date = record.updatedAt ?? record.createdAt;
      final key = date == null ? '更早' : _dayHeading(date);
      groups.putIfAbsent(key, () => []).add(record);
    }
    // 列表项按“日期标题、一条记录”铺平，交给 ListView.builder 只建可视范围
    // 内的几项；每读一页也不再重新生成整份 children。
    final entries = <Object>[
      for (final entry in groups.entries) ...[entry.key, ...entry.value],
    ];
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        theme.space.page,
        theme.space.xs,
        theme.space.page,
        theme.space.xl,
      ),
      itemCount: entries.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == entries.length) {
          // 列表末尾这一项建出来，说明已经滚到离底部一屏以内，自动接着读。
          _scheduleLoadMore();
          return LoadMoreFooter(
            label: '读取更早的记录',
            loading: _loadingMore,
            onPressed: _loadMore,
          );
        }
        return switch (entries[index]) {
          final String heading => Padding(
            padding: EdgeInsets.only(
              top: theme.space.md,
              bottom: theme.space.xs,
              left: 2,
            ),
            child: Text(
              heading,
              style: theme.text.labelLarge.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          ),
          final ConversationRecord record => _recordTile(theme, record),
          _ => const SizedBox.shrink(),
        };
      },
    );
  }

  /// 滚到列表末尾时自动读下一页；按钮留着，读取失败时可以再点一次。
  void _scheduleLoadMore() {
    if (!_hasMore || _loadingMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadMore();
    });
  }

  /// 日期分组的标题：今天与昨天直接写出来，其余写日期与星期。
  String _dayHeading(DateTime date) {
    final now = AppScope.of(context).timePolicy.now;
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天 · ${dayLabel(date)}';
    if (diff == 1) return '昨天 · ${dayLabel(date)}';
    return dayLabel(date);
  }

  Future<void> _changeGoal(ConversationRecord record) async {
    final choice = await showGoalChoice(
      context,
      goals: _goals,
      initialGoalId: record.goalId,
      title: '这条记录属于哪个目标',
      note: '目标用于筛选和后续建议，已有记录保持原样。',
    );
    if (choice == null || !mounted) return;
    try {
      await AppScope.of(context).chat.discussion
          .setGoal(record.id, choice.goalId);
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '更改记录的目标',
        kind: 'records_goal',
        kept: '原来的归属没有改动',
        next: '可以重新选择一次',
      );
      showToast(context, message);
    }
  }

  String _recordTitle(ConversationRecord record) =>
      record.title ??
      _questions[record.id]?.question.displayStem ??
      record.displayTitle;

  /// 清空一条学习记录；消息与作答一起删除。
  Future<void> _clear(ConversationRecord record) async {
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '清空这条记录',
      content: Text(
        '清空“${_recordTitle(record)}”后，这条记录的消息与作答将被删除且无法恢复。'
        '确定清空这条记录？',
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        forui.FButton(
          variant: forui.FButtonVariant.destructive,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('清空'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppScope.of(context).chat.discussion.clear(record.id);
      await _load();
      if (!mounted) return;
      showToast(context, '已清空这条记录');
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '清空这条记录',
        kind: 'records_clear',
        kept: '这条记录还在',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  String _clip(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 60) return flat;
    return '${flat.substring(0, 60)}…';
  }

  /// 一条学习记录：标题下先列类型与状态标签，再给最近一次提问或作答，最后
  /// 一行写消息数、归属与时间。原来这些用间隔号连成两行灰字，状态和时间
  /// 常被截断；拆开之后，有草稿的记录在列表里一眼能认出来。
  Widget _recordTile(ZhixinTheme theme, ConversationRecord record) {
    final question = _questions[record.id];
    final title = _recordTitle(record);
    final preview = (record.preview ?? '').trim();
    final hasDraft = record.hasDraft;
    final attempt = question?.lastAttempt;
    final answer = attempt?.userAnswer?.trim();
    Assessment? modelAssessment;
    for (final assessment
        in _assessments[attempt?.id] ?? const <Assessment>[]) {
      if (assessment.kind == AssessmentKind.model) modelAssessment = assessment;
    }
    final muted = theme.text.bodySmall.copyWith(
      color: theme.colors.onSurfaceVariant,
    );
    final submittedAt = question == null || hasDraft
        ? null
        : question.lastAttempt?.submittedAt;
    final footer = [
      '${record.messageCount} 条消息',
      _goalLabel(record.goalId),
      if (submittedAt != null) '作答于 ${shortTime(submittedAt)}',
    ].join('，');
    final active = hasDraft || record.open;
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm - 2),
      child: forui.FTile(
        prefix: LeadingIcon(
          question != null
              ? FLucideIcons.notebookPen
              : FLucideIcons.messageCircle,
          tone: hasDraft
              ? TagTone.attention
              : active
              ? TagTone.accent
              : TagTone.muted,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            TagRow(
              children: [
                if (question != null) ...[
                  const StatusTag('题目'),
                  hasDraft
                      ? const StatusTag('有未提交草稿', tone: TagTone.attention)
                      : StatusTag(
                          statusLabel(question.status),
                          tone: question.status == 'correct'
                              ? TagTone.muted
                              : TagTone.accent,
                        ),
                ] else ...[
                  const StatusTag('讨论'),
                  StatusTag(
                    record.open ? '进行中' : '已结束',
                    tone: record.open ? TagTone.accent : TagTone.muted,
                  ),
                ],
                if (DiscussionActivity.isGenerating(record.id))
                  const StatusTag('正在生成回答', tone: TagTone.accent),
                if (question?.question.sourceRef case final source?)
                  StatusTag(source, icon: FLucideIcons.bookmark),
                if (question == null && record.hasMaterial)
                  StatusTag(record.materialLabel, icon: FLucideIcons.bookOpen),
              ],
            ),
            if (preview.isNotEmpty && preview != title)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.4),
                ),
              ),
            if (answer != null && answer.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '作答：${_clip(answer)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurface,
                  ),
                ),
              ),
            if (attempt != null && attempt.submitted)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '自评：${attempt.selfResult}'
                  '${modelAssessment == null ? '' : '，判断：${_clip(modelAssessment.result)}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muted.copyWith(height: 1.4),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                footer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
            if (hasDraft)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: forui.FButton(
                  variant: forui.FButtonVariant.secondary,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => _openLearning(record.id),
                  prefix: const Icon(FLucideIcons.notebookPen),
                  child: const Text('继续作答'),
                ),
              ),
          ],
        ),
        suffix: moreMenu(
          items: [
            if (question != null && !hasDraft)
              ZhixinMenuItem(
                label: '去作答',
                onSelected: () => _openLearning(record.id),
              ),
            if (question != null && !hasDraft && attempt?.submitted == true)
              ZhixinMenuItem(
                label: '复查（先不看上次）',
                onSelected: () => _openLearningRedo(record.id),
              ),
            if (hasDraft)
              ZhixinMenuItem(
                label: '打开讨论',
                onSelected: () => _openDiscussion(record.id),
              ),
            ZhixinMenuItem(label: '改归属', onSelected: () => _changeGoal(record)),
            ZhixinMenuItem(label: '清空记录', onSelected: () => _clear(record)),
          ],
        ),
        onPress: () => question != null
            ? _openLearning(record.id)
            : _openDiscussion(record.id),
      ),
    );
  }
}
