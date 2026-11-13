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
import 'discussion_page.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'plan_page.dart';
import 'study_entry.dart';
import 'study_plan_page.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_toast.dart';

/// 新问题与继续学习各有入口，首页不再隐式续接上一条讨论。
class NowPage extends StatefulWidget {
  const NowPage({
    super.key,
    required this.isActive,
    this.dataVersion = 0,
    required this.onOpenLearning,
    required this.onOpenPlan,
    required this.onOpenRecords,
    required this.onOpenMaterials,
    required this.onOpenMemory,
    required this.onOpenSettings,
  });
  final bool isActive;

  /// 整库恢复、清空与导入之后加一；页面据此在原处重读，不被换掉重建。
  final int dataVersion;
  final Future<void> Function(int questionId) onOpenLearning;
  final VoidCallback onOpenPlan;
  final VoidCallback onOpenRecords;
  final VoidCallback onOpenMaterials;
  final VoidCallback onOpenMemory;
  final VoidCallback onOpenSettings;

  @override
  State<NowPage> createState() => _NowPageState();
}

class _NowPageState extends State<NowPage> {
  final _input = TextEditingController();
  NowActivity? _activity;
  List<ContinueEntry> _continue = const [];
  bool _loading = true;
  bool _started = false;
  bool _opening = false;

  /// 两段各自读取、各自出错；一段失败不挡住另一段。
  String? _activityError;
  String? _continueError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    DiscussionActivity.generating.removeListener(_onGeneratingChanged);
    DiscussionActivity.generating.addListener(_onGeneratingChanged);
    if (_started) return;
    _started = true;
    _load();
  }

  /// 生成开始或结束时重画卡片；消息数与摘要等下次进入页面时重新读取。
  void _onGeneratingChanged() {
    if (!mounted || !widget.isActive) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant NowPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive) return;
    if (!oldWidget.isActive || oldWidget.dataVersion != widget.dataVersion) {
      _load();
    }
  }

  @override
  void dispose() {
    DiscussionActivity.generating.removeListener(_onGeneratingChanged);
    _input.dispose();
    super.dispose();
  }

  /// 活动卡与“继续上次”互不依赖，分开读取；一段失败时只在这一段说明，
  /// 另一段照常显示，刷新或页内重试都不会清掉已经读到的内容。
  Future<void> _load() async {
    await Future.wait([_loadActivity(), _loadContinue()]);
    if (!mounted || !_loading) return;
    setState(() => _loading = false);
  }

  Future<void> _loadActivity() async {
    final scope = AppScope.of(context);
    try {
      final activity = await scope.chat.context.loadActivity();
      if (!mounted) return;
      setState(() {
        _activity = activity;
        _activityError = null;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _activityError = describeFailure(
          context,
          error,
          stack,
          action: '读取首页的学习安排',
          kind: 'now_activity_read',
          kept: '本机已经保存的安排没有改动',
          next: '可以点「重试」再读一次',
        );
      });
    }
  }

  Future<void> _loadContinue() async {
    final scope = AppScope.of(context);
    try {
      final entries = await scope.study.continueLast.load();
      if (!mounted) return;
      setState(() {
        _continue = entries;
        _continueError = null;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _continueError = describeFailure(
          context,
          error,
          stack,
          action: '读取最近的学习记录',
          kind: 'now_continue_read',
          kept: '本机已经保存的记录没有改动',
          next: '可以点「重试」再读一次',
        );
      });
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) await _load();
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
    await _open(
      DiscussionPage(
        initialText: text,
        initialImages: photos,
        startNew: true,
        onSubmitted: () {
          if (mounted) _input.clear();
        },
      ),
    );
    if (mounted) setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final activity = _activity;
    final showActivity = !_loading && activity != null && !activity.isEmpty;
    return forui.FScaffold(
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
          ZhixinHeaderAction(
            icon: FLucideIcons.settings,
            tooltip: '设置',
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      child: PageWidth(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            key: const PageStorageKey('now-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: theme.space.pageInsets(),
            children: [
              // 已有预约或待办时，当前活动排在输入区之前：02 第 5 节要求首屏
              // 给出可开始的内容、预计时长与开始按钮，原来它在两张入口卡之后，
              // 手机上常常落到第二屏。
              if (_activityError != null)
                InlineNotice(
                  message: _activityError!,
                  onRetry: () => _loadActivity(),
                ),
              // 活动卡在读完之后才插到输入区上方；展开而不是直接出现，
              // 输入区随之平滑下移，用户不会以为点错了地方。
              ExpandReveal(
                visible: showActivity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: showActivity
                      ? _activitySections(theme, activity)
                      : const [],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(
                  top: showActivity ? theme.space.section - 4 : 0,
                ),
                child: Text(
                  '提出一个问题',
                  style: showActivity
                      ? theme.text.titleMedium
                      : theme.text.headlineMedium,
                ),
              ),
              SizedBox(height: theme.space.xs),
              Text(
                '可以直接输入文字，也可以添加题目照片。',
                style: theme.text.bodyMedium.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.lg),
              _composer(theme),
              SizedBox(height: theme.space.md),
              _shortcuts(theme),
              if (_loading)
                const FadeIn(
                  rise: false,
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: forui.FCircularProgress()),
                  ),
                ),
              SectionHeading(
                title: '继续上次',
                action: forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: widget.onOpenRecords,
                  child: const Text('查看记录'),
                ),
              ),
              if (_continueError != null)
                InlineNotice(
                  message: _continueError!,
                  onRetry: () => _loadContinue(),
                ),
              // 读完之后整段淡入一次；之后返回首页的重读只换内容，不再闪动。
              FadeIn(
                trigger: _loading,
                playOnInit: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in _continue) _continueCard(theme, entry),
                    if (!_loading &&
                        _continueError == null &&
                        _continue.isEmpty)
                      const forui.FCard(
                        child: EmptyState(
                          icon: FLucideIcons.bookmark,
                          title: '随时回来继续学习',
                          description: '开始提问后，讨论和材料位置会保存在这里。',
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
      onPress: () => _open(StudyPlanPage(planId: plan.id)),
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
          if (mounted) await _load();
        } else {
          await _open(DiscussionPage(conversationId: record.id));
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: feature ? theme.colors.primary : theme.colors.card,
          borderRadius: feature ? theme.radius.feature : theme.radius.card,
          border: feature
              ? null
              : Border.all(color: theme.colors.outlineVariant),
        ),
        child: Padding(
          padding: EdgeInsets.all(feature ? 20 : theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(FLucideIcons.clock, size: 16, color: soft),
                  SizedBox(width: theme.space.xs + 2),
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
                style:
                    (feature ? theme.text.titleLarge : theme.text.titleMedium)
                        .copyWith(
                          color: ink,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
              ),
              if (text != null && text.isNotEmpty) ...[
                SizedBox(height: theme.space.xs + 2),
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
      ),
    );
  }

  Future<void> _openActivity(PlanItem item) async {
    await openPlanItem(context, item);
    if (mounted) await _load();
  }

  Future<void> _openPlanItem(PlanItem item) {
    return _open(PlanPage(isActive: true, initialItemId: item.id));
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
            width: _focused ? 1.5 : 1,
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
