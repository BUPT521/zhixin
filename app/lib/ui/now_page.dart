import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../application/context_service.dart';
import '../application/continue_service.dart';
import '../domain/models/conversation.dart';
import '../domain/models/study.dart';
import '../domain/models/study_plan.dart';
import 'capture_entry.dart';
import 'discussion_activity.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_toast.dart';

/// 新问题与继续学习各有入口，首页不再隐式续接上一条讨论。
class NowPage extends StatefulWidget {
  const NowPage({
    super.key,
    required this.activeTab,
    this.tabIndex = 0,
    required this.onOpenLearning,
    required this.onOpenPlan,
    required this.onOpenRecords,
    required this.onOpenMaterials,
    required this.onOpenMemory,
  });

  /// 底栏当前栏的下标；页面自己监听，父级切栏时不再重建这一栏。
  final ValueListenable<int> activeTab;
  final int tabIndex;
  final Future<void> Function(String questionId) onOpenLearning;
  final VoidCallback onOpenPlan;
  final VoidCallback onOpenRecords;
  final VoidCallback onOpenMaterials;
  final VoidCallback onOpenMemory;

  @override
  State<NowPage> createState() => _NowPageState();
}

class _NowPageState extends State<NowPage> {
  final _input = TextEditingController();
  bool _opening = false;

  /// 首页顶部摘要的订阅：当前活动与继续入口一次读回（ADR-0014）。
  ///
  /// 切到这一栏时才建立，之后常驻；跳去学习、讨论再回来不再手动重读。
  Stream<NowHome>? _stream;

  /// 下拉刷新之后等新结果回来再收起转圈；没有结果时按超时放行。
  Completer<void>? _refreshWaiter;

  bool get _active => widget.activeTab.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    widget.activeTab.addListener(_onActiveChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    DiscussionActivity.generating.removeListener(_onGeneratingChanged);
    DiscussionActivity.generating.addListener(_onGeneratingChanged);
    // 未显示的页面不提前订阅，也不在后台读；切到首页时再开始。
    if (_stream == null && _active) _stream = _createStream();
  }

  @override
  void didUpdateWidget(covariant NowPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTab != widget.activeTab) {
      oldWidget.activeTab.removeListener(_onActiveChanged);
      widget.activeTab.addListener(_onActiveChanged);
    }
  }

  @override
  void dispose() {
    widget.activeTab.removeListener(_onActiveChanged);
    DiscussionActivity.generating.removeListener(_onGeneratingChanged);
    _refreshWaiter?.complete();
    _refreshWaiter = null;
    _input.dispose();
    super.dispose();
  }

  Stream<NowHome> _createStream() =>
      AppScope.of(context).study.continueLast.watchHome();

  /// 换一条新流：下拉刷新走这里，写入之后的重读由数据层完成。
  Future<void> _refresh() {
    final waiter = Completer<void>();
    _refreshWaiter = waiter;
    setState(() => _stream = _createStream());
    return waiter.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  /// 新结果回来了：放行等待中的刷新转圈。
  void _onHome(NowHome _) {
    _refreshWaiter?.complete();
    _refreshWaiter = null;
  }

  void _onHomeError(Object error, StackTrace stack) {
    _refreshWaiter?.complete();
    _refreshWaiter = null;
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取首页的学习安排',
      kind: 'now_read',
      kept: '屏幕上已经显示的内容保持不变',
      next: '可以下拉刷新再读一次',
    );
    showToast(context, message);
  }

  /// 切到这一栏时接着订阅；已经有的订阅常驻，切回来不重新读。
  void _onActiveChanged() {
    if (!mounted || !_active) return;
    if (_stream == null) setState(() => _stream = _createStream());
  }

  /// 生成开始或结束时重画卡片；消息数与摘要随订阅更新。
  void _onGeneratingChanged() {
    if (!mounted || !_active) return;
    setState(() {});
  }

  /// 首页取图：先把图片拍好或选好，再带着文字进入新讨论。
  ///
  /// 取消取图就留在首页，输入框里的文字原样保留。如果先进页面再取图，取消
  /// 之后文字已经随着页面打开过，退回首页时原稿就没了。
  Future<void> _pickForDiscussion() async {
    if (_opening) return;
    final source = await chooseCaptureSource(context);
    if (source == null || !mounted) return;
    await _newDiscussion(imageSource: source);
  }

  /// 新讨论带着首页输入框的文字与图片进入；首条消息写进记录之后首页才清空。
  ///
  /// 没有发送就退回首页时草稿仍在，用户不必重写已经想好的问题。
  Future<void> _newDiscussion({ImageSource? imageSource}) async {
    if (_opening) return;
    final text = _input.text;
    final photos = <XFile>[];
    if (imageSource != null) {
      setState(() => _opening = true);
      try {
        final picked = await pickQuestionImage(context, imageSource);
        if (picked == null || !mounted) return;
        photos.add(picked);
      } catch (error) {
        if (!mounted) return;
        showToast(context, captureErrorText(error));
        return;
      } finally {
        if (mounted) setState(() => _opening = false);
      }
    }
    if (!mounted) return;
    setState(() => _opening = true);
    FocusManager.instance.primaryFocus?.unfocus();
    await openNewDiscussion(
      context,
      initialText: text,
      initialImages: photos,
      onSubmitted: () {
        if (mounted) _input.clear();
      },
    );
    if (mounted) setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return TabScaffold(
      header: ZhixinHeader(
        nested: false,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [ZhixinMark(), SizedBox(width: 10), Text('知新')],
        ),
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.brain,
            tooltip: '记忆',
            onPressed: widget.onOpenMemory,
          ),
        ],
      ),
      child: PageWidth(
        child: LiveView<NowHome>(
          stream: _stream,
          onData: _onHome,
          onError: _onHomeError,
          builder: (context, home, loading) =>
              _homeBody(theme, home, loading: loading),
        ),
      ),
    );
  }

  /// 一屏内容：当前活动在输入区之前，继续入口在最后。
  ///
  /// 首读用与卡片同高的骨架占位，读完原位替换；下拉刷新换一条新流，新结果
  /// 回来时收起转圈（ADR-0014）。
  Widget _homeBody(ZhixinTheme theme, NowHome? home, {required bool loading}) {
    final activity = home?.activity;
    final showActivity = !loading && activity != null && !activity.isEmpty;
    final entries = home?.continueEntries ?? const <ContinueEntry>[];
    final sections = <WidgetBuilder>[
      // 当前活动置于输入区之前，让开始按钮留在首屏。
      (_) => ExpandReveal(
        visible: showActivity,
        child: showActivity
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _activitySections(theme, activity),
              )
            : const SizedBox.shrink(),
      ),
      (_) => Padding(
        padding: EdgeInsets.only(top: showActivity ? theme.space.xl : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '提出一个问题',
              style: showActivity
                  ? theme.text.titleMedium
                  : theme.text.headlineMedium,
            ),
            SizedBox(height: theme.space.xs),
            Text(
              '可以直接输入文字，也可以添加题目照片。',
              style: theme.text.bodyMedium.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            SizedBox(height: theme.space.lg),
          ],
        ),
      ),
      (_) => _composer(theme),
      (_) => Padding(
        padding: EdgeInsets.only(top: theme.space.md),
        child: _shortcuts(theme),
      ),
      (_) => SectionHeading(
        title: '继续上次',
        action: forui.FButton(
          variant: forui.FButtonVariant.ghost,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: widget.onOpenRecords,
          child: const Text('查看记录'),
        ),
      ),
    ];
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        key: const PageStorageKey('now-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: theme.space.pageInsets(),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverList.builder(
                  key: const ValueKey('now-actions'),
                  itemCount: sections.length,
                  itemBuilder: (context, index) => sections[index](context),
                ),
                FadeIn.sliver(
                  key: const ValueKey('continue-content'),
                  trigger: loading,
                  playOnInit: false,
                  child: _continueList(theme, entries, loading: loading),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueList(
    ZhixinTheme theme,
    List<ContinueEntry> entries, {
    required bool loading,
  }) {
    if (!loading && entries.isEmpty) {
      return const SliverToBoxAdapter(
        child: forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.bookmark,
            title: '随时回来继续学习',
            description: '开始提问后，讨论和材料位置会保存在这里。',
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: entries.length + (loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (loading && index == 0) {
          return const ListSkeleton(rows: 2, rowHeight: 76);
        }
        return _continueCard(theme, entries[index - (loading ? 1 : 0)]);
      },
    );
  }

  /// 输入区：卡片底色与页面区分开，聚焦时描边换成主色；发送按钮靠右，
  /// 与图片入口分在一行的两端，拇指够得着，也不会误点。
  Widget _composer(ZhixinTheme theme) => _ComposerFrame(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        forui.FTextField(
          control: .managed(controller: _input),
          minLines: 2,
          maxLines: 5,
          hint: '输入问题，说明希望获得的帮助…',
          style: .delta(
            border: .delta([.all(InputBorder.none)]),
            color: .delta([.all(Colors.transparent)]),
            contentPadding: const .value(EdgeInsets.zero),
          ),
        ),
        SizedBox(height: theme.space.sm),
        Row(
          children: [
            ZhixinIconButton(
              tooltip: '添加图片',
              variant: forui.FButtonVariant.secondary,
              onPressed: _opening ? null : _pickForDiscussion,
              icon: FLucideIcons.imagePlus,
            ),
            const Spacer(),
            forui.FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: _opening ? null : _newDiscussion,
              prefix: const Icon(FLucideIcons.arrowUp),
              child: const Text('发送问题'),
            ),
          ],
        ),
      ],
    ),
  );

  /// 窄屏或放大文字时，次级入口改为上下排列。
  Widget _shortcuts(ZhixinTheme theme) {
    final tiles = [
      EntryTile(
        icon: FLucideIcons.bookOpen,
        title: '从材料开始学习',
        subtitle: '导入材料，引用原文',
        onTap: widget.onOpenMaterials,
      ),
      EntryTile(
        icon: FLucideIcons.route,
        title: '系统学习',
        subtitle: '查看学习进度与预约',
        onTap: widget.onOpenPlan,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < 290 * textScale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              tiles[0],
              SizedBox(height: theme.space.sm),
              tiles[1],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: tiles[0]),
            SizedBox(width: theme.space.md),
            Expanded(child: tiles[1]),
          ],
        );
      },
    );
  }

  Widget _continueCard(ZhixinTheme theme, ContinueEntry entry) {
    final plan = entry.plan;
    if (plan != null) return _planCard(theme, plan);
    return _conversationCard(theme, entry.record!);
  }

  Widget _planCard(ZhixinTheme theme, StudyPlan plan) {
    final updatedAt = plan.updatedAt;
    final next = plan.nextStepTitle?.trim();
    final clue = next == null || next.isEmpty ? '没有待完成的步骤' : '下一步：$next';
    return _ContinueTile(
      leading: const LeadingIcon(FLucideIcons.route),
      title: plan.title,
      tags: [
        const StatusTag('系统学习', tone: TagTone.accent),
        StatusTag(plan.progressLabel),
      ],
      time: updatedAt == null ? null : '上次推进 ${shortTime(updatedAt)}',
      clue: clue,
      onPress: () async {
        await openStudyPlan(context, plan.id);
      },
    );
  }

  Widget _conversationCard(ZhixinTheme theme, ConversationRecord record) {
    final hasDraft = record.hasDraft;
    final time = hasDraft
        ? (record.draftUpdatedAt ?? record.updatedAt)
        : (record.updatedAt ?? record.lastMessageAt);
    final timeLabel = time == null
        ? null
        : hasDraft
        ? '上次写于 ${shortTime(time)}'
        : record.messageCount == 0
        ? '创建于 ${shortTime(time)}'
        : '最后一条 ${shortTime(time)}';
    final question = _firstLine(record.lastUserMessage);
    final clue = hasDraft
        ? record.draftSnippet == null
              ? '还没有写下内容，打开接着写'
              : '写到了：${record.draftSnippet}'
        : question == null
        ? '还没有提问'
        : '上次问：$question';
    final active = hasDraft || record.open;
    return _ContinueTile(
      leading: LeadingIcon(
        hasDraft ? FLucideIcons.notebookPen : FLucideIcons.messageCircle,
        tone: hasDraft
            ? TagTone.attention
            : active
            ? TagTone.accent
            : TagTone.muted,
      ),
      title: _recordTitle(record),
      tags: [
        if (hasDraft)
          const StatusTag('未提交草稿', tone: TagTone.attention)
        else
          StatusTag(
            record.open ? '讨论' : '已结束的讨论',
            tone: record.open ? TagTone.neutral : TagTone.muted,
          ),
        if (DiscussionActivity.isGenerating(record.id))
          const StatusTag('正在生成回答', tone: TagTone.accent),
        if (record.hasMaterial)
          StatusTag(record.materialLabel, icon: FLucideIcons.bookOpen),
      ],
      time: timeLabel,
      clue: clue,
      resume: hasDraft,
      onPress: () async {
        if (hasDraft) {
          await widget.onOpenLearning(record.id);
        } else {
          await openDiscussion(context, record.id);
        }
      },
    );
  }

  /// 有标题时用标题；没有标题时用最近一次提问的第一行，其次用记录类型。
  static String _recordTitle(ConversationRecord record) {
    final title = record.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return _firstLine(record.lastUserMessage) ?? record.displayTitle;
  }

  /// 卡片上只放第一行，避免把整段消息塞进标题或线索。
  static String? _firstLine(String? text) {
    final line = text?.split('\n').first.trim();
    return line == null || line.isEmpty ? null : line;
  }

  /// 正在进行与接下来各占一节；没有预约时，最近到期的待办放在“接下来”。
  /// 排在最前的一项用主色卡片突出，其余用普通卡片。
  List<Widget> _activitySections(ZhixinTheme theme, NowActivity activity) {
    final sections = <Widget>[];
    final ongoing = activity.ongoing;
    if (ongoing != null) {
      sections.add(
        SectionHeading(title: '正在进行', action: _planAction(), first: true),
      );
      sections.add(
        _scheduledActivityCard(theme, ongoing, ongoing: true, feature: true),
      );
    }
    final next = activity.next;
    if (next != null) {
      sections.add(
        SectionHeading(
          title: '接下来',
          action: ongoing == null ? _planAction() : null,
          first: ongoing == null,
        ),
      );
      sections.add(
        _scheduledActivityCard(
          theme,
          next,
          ongoing: false,
          feature: ongoing == null,
        ),
      );
    } else if (activity.pending case final pending?) {
      sections.add(
        SectionHeading(
          title: '接下来',
          action: ongoing == null ? _planAction() : null,
          first: ongoing == null,
        ),
      );
      sections.add(
        _pendingActivityCard(theme, pending, feature: ongoing == null),
      );
    }
    return sections;
  }

  Widget _planAction() => forui.FButton(
    variant: forui.FButtonVariant.ghost,
    size: forui.FButtonSizeVariant.sm,
    mainAxisSize: MainAxisSize.min,
    onPress: widget.onOpenPlan,
    child: const Text('查看安排'),
  );

  Widget _scheduledActivityCard(
    ZhixinTheme theme,
    ActivityEntry entry, {
    required bool ongoing,
    required bool feature,
  }) {
    final block = entry.scheduled.block;
    final minutes = block.endAt.difference(block.startAt).inMinutes;
    final status =
        '${ongoing ? '正在进行' : '接下来'} · '
        '${shortTime(block.startAt)}–${clockOf(block.endAt)}';
    return _activityCard(
      theme,
      entry.item,
      label: status,
      duration: minutes > 0 ? '$minutes 分钟' : null,
      note: entry.item.note ?? entry.scheduled.itemNote,
      feature: feature,
    );
  }

  Widget _pendingActivityCard(
    ZhixinTheme theme,
    PlanItem item, {
    required bool feature,
  }) {
    final estimate = item.estMinutes == null
        ? ''
        : ' · 约 ${item.estMinutes} 分钟';
    return _activityCard(
      theme,
      item,
      label: '待开始$estimate',
      note: item.note,
      feature: feature,
    );
  }

  /// 有原题或材料页时直接打开学习内容；只有说明的事项仍进入事项详情。
  ///
  /// [feature] 为真的一张是首屏的主角：主色底、反白文字，开始按钮占满一行；
  /// 其余活动用普通卡片，避免一页里出现两个同样醒目的按钮。
  Widget _activityCard(
    ZhixinTheme theme,
    PlanItem item, {
    required String label,
    String? duration,
    String? note,
    required bool feature,
  }) {
    final text = note?.trim();
    final canOpen = item.isStudyStep || item.conversationId != null;
    final ink = feature ? theme.colors.onPrimary : theme.colors.onSurface;
    final soft = feature
        ? theme.colors.onPrimary.withValues(alpha: 0.82)
        : theme.colors.onSurfaceVariant;
    final primaryAction = forui.FButton(
      // 主色卡片上用浅底按钮；普通卡片也用浅底，让首屏只有一个最醒目的开始。
      variant: forui.FButtonVariant.secondary,
      mainAxisSize: feature ? MainAxisSize.max : MainAxisSize.min,
      onPress: canOpen ? () => _openActivity(item) : () => _openPlanItem(item),
      prefix: Icon(canOpen ? FLucideIcons.play : FLucideIcons.calendarClock),
      child: Text(canOpen ? '开始学习' : '查看事项'),
    );
    final secondaryAction = canOpen
        ? feature
              ? TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colors.onPrimary,
                    textStyle: theme.text.labelLarge,
                  ),
                  onPressed: () => _openPlanItem(item),
                  icon: const Icon(FLucideIcons.calendarClock, size: 18),
                  label: const Text('查看事项'),
                )
              : forui.FButton(
                  variant: forui.FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => _openPlanItem(item),
                  prefix: const Icon(FLucideIcons.calendarClock),
                  child: const Text('查看事项'),
                )
        : null;
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.sm),
      // 卡片与内边距交给 forui.FCard：首屏主角那张用主色底与 feature 圆角，
      // 其余用主题卡片样式。Forui 0.27 的 FCard 没有 feature 变体，这里用
      // style 的 delta 表达同一套取值，视觉与原来自绘的卡片一致。
      child: forui.FCard(
        style: forui.FCardStyleDelta.delta(
          decoration: forui.DecorationDelta.shapeDelta(
            color: feature ? theme.colors.primary : theme.colors.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: feature ? theme.radius.feature : theme.radius.card,
              side: feature
                  ? BorderSide.none
                  : BorderSide(color: theme.colors.outlineVariant),
            ),
          ),
          padding: forui.EdgeInsetsGeometryDelta.value(
            EdgeInsets.all(feature ? 20 : theme.space.lg),
          ),
        ),
        builder: (context, style, child) =>
            Padding(padding: style.padding, child: child),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(FLucideIcons.clock, size: 16, color: soft),
                SizedBox(width: theme.space.tight),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.text.labelLarge.copyWith(
                      color: soft,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (duration != null)
                  Text(
                    duration,
                    style: theme.text.labelLarge.copyWith(color: soft),
                  ),
              ],
            ),
            SizedBox(height: theme.space.sm),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: (feature ? theme.text.titleLarge : theme.text.titleMedium)
                  .copyWith(
                    color: ink,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
            ),
            if (text != null && text.isNotEmpty) ...[
              SizedBox(height: theme.space.tight),
              Text(
                '说明：$text',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.text.bodySmall.copyWith(color: soft),
              ),
            ],
            SizedBox(height: theme.space.lg),
            if (feature) ...[
              primaryAction,
              if (secondaryAction != null) ...[
                SizedBox(height: theme.space.xs),
                Center(child: secondaryAction),
              ],
            ] else
              Wrap(
                spacing: theme.space.sm,
                runSpacing: theme.space.sm,
                children: [primaryAction, ?secondaryAction],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openActivity(PlanItem item) async {
    await openPlanItem(context, item);
  }

  Future<void> _openPlanItem(PlanItem item) async {
    await openPlanDetail(context, item.id);
  }
}

/// 输入区外框：卡片底色加描边，输入框聚焦时描边换成主色。
class _ComposerFrame extends StatefulWidget {
  const _ComposerFrame({required this.child});
  final Widget child;

  @override
  State<_ComposerFrame> createState() => _ComposerFrameState();
}

class _ComposerFrameState extends State<_ComposerFrame> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) => setState(() => _focused = value),
      // 描边宽度固定 1.5：边框宽度会进内边距，一改就整块重新布局、文字跳半个
      // 像素；聚焦只插值颜色，输入区的位置与大小全程不变。
      child: AnimatedContainer(
        duration: context.motionOf(theme.motion.fast),
        curve: theme.motion.move,
        padding: EdgeInsets.fromLTRB(
          theme.space.lg,
          theme.space.lg,
          theme.space.md,
          theme.space.md,
        ),
        decoration: BoxDecoration(
          color: theme.colors.card,
          borderRadius: theme.radius.feature,
          border: Border.all(
            color: _focused ? theme.colors.primary : theme.colors.outline,
            width: 1.5,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// “继续上次”的一行：类型图标、标题、状态标签与时间，再写一句继续位置。
///
/// 原来把类型、状态、材料与时间用间隔号连成一行灰字，放不下就截断，最要紧
/// 的“有草稿”和时间常常被截掉。这里把状态拆成标签，时间单独靠右。
class _ContinueTile extends StatelessWidget {
  const _ContinueTile({
    required this.leading,
    required this.title,
    required this.tags,
    required this.clue,
    required this.onPress,
    this.time,
    this.resume = false,
  });

  final Widget leading;
  final String title;
  final List<Widget> tags;
  final String? time;
  final String clue;
  final bool resume;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final muted = theme.text.bodySmall.copyWith(
      color: theme.colors.onSurfaceVariant,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.sm),
      child: forui.FTile(
        prefix: leading,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: TagRow(children: tags)),
                if (time != null) ...[
                  const SizedBox(width: 8),
                  Text(time!, style: muted),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(clue, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        suffix: Icon(
          resume ? FLucideIcons.play : FLucideIcons.chevronRight,
          color: resume
              ? theme.colors.attention
              : theme.colors.onSurfaceVariant,
        ),
        onPress: onPress,
      ),
    );
  }
}
