import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/capacity.dart';
import 'date_time_dialogs.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 空档确认之后要做的事：有原预约时可以改期，也可以再加一段。
enum _BookingAction { replace, append }

/// 打开时间预算与优先顺序；用户点选算好的空档后，只预约那一项。
Future<void> showCapacitySheet(BuildContext context) async {
  await showZhixinSheet<void>(
    context: context,
    builder: (_) => const _CapacitySheet(),
  );
}

class _CapacitySheet extends StatefulWidget {
  const _CapacitySheet();

  @override
  State<_CapacitySheet> createState() => _CapacitySheetState();
}

class _CapacitySheetState extends State<_CapacitySheet> {
  CapacityPlan? _plan;
  bool _loading = true;
  bool _started = false;
  String? _notice;
  String _windowStart = '19:00';
  String _windowEnd = '21:30';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      final plan = await scope.study.capacity.computeThisWeek();
      if (!mounted) return;
      // 结果回来时若还在展开动画里，等动画结束再填，免得滑入途中高度跳一次。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _loading = false;
        _notice = null;
        _windowStart = plan.windowStart;
        _windowEnd = plan.windowEnd;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _plan = null;
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '计算可用时间',
          kind: 'capacity_compute',
          kept: '已有预约与课表没有改动',
          next: '可以合上再打开重试',
        );
      });
    }
  }

  Future<void> _editWindow() async {
    final start = await _pickTime(_windowStart);
    if (start == null || !mounted) return;
    final end = await _pickTime(_windowEnd);
    if (end == null || !mounted) return;
    final scope = AppScope.of(context);
    try {
      await scope.study.capacity.setWindow(start: start, end: end);
      setState(() {
        _windowStart = start;
        _windowEnd = end;
        _loading = true;
        _plan = null;
      });
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存常用学习时段',
          kind: 'capacity_window',
          kept: '原来的时段没有改动',
          next: '可以再选一次',
        ),
      );
    }
  }

  Future<String?> _pickTime(String current) async {
    final parts = current.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 19,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
    final picked = await showZhixinTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked == null) return null;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(picked.hour)}:${two(picked.minute)}';
  }

  /// 写入之前先说明这次会新建还是改期、从什么时间改到什么时间。
  ///
  /// 点选空档原先只弹一条成功提示，用户要到安排页才看得出哪条预约变了；
  /// 预览把这一项的原时间与目标时间放在确认框里，课表与其他预约不在其中。
  Future<_BookingAction?> _confirmBooking(
    CapacityCandidate candidate,
    CapacityWindow window,
  ) async {
    final item = candidate.item;
    final fromStart = candidate.movableStart;
    final fromEnd = candidate.movableEnd;
    final hasSingleExisting = fromStart != null && fromEnd != null;
    final hasExisting = hasSingleExisting || candidate.scheduledMinutes > 0;
    final change = hasSingleExisting
        ? '原预约：${_rangeText(fromStart, fromEnd)}\n'
              '改到：${_windowText(window)}'
        : hasExisting
        ? '已有预约合计 ${candidate.scheduledMinutes} 分钟，这次再加一段：'
              '${_windowText(window)}'
        : '新建预约：${_windowText(window)}';
    final theme = context.zhixin;
    final action = await showZhixinAlert<_BookingAction>(
      context: context,
      title: '按这个空档预约',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('「${item.title}」', style: theme.text.titleMedium),
          const SizedBox(height: 8),
          Text(change),
          const SizedBox(height: 8),
          Text(
            hasExisting
                ? '这次只调整这一项，课表与其他预约保持原样；'
                      '选「再加一段」会保留原预约。'
                : '这次只调整这一项，课表与其他预约保持原样。',
            style: theme.text.bodySmall,
          ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (hasExisting)
          forui.FButton(
            variant: forui.FButtonVariant.ghost,
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.of(context).pop(_BookingAction.append),
            child: const Text('再加一段'),
          ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(_BookingAction.replace),
          child: Text(hasExisting ? '改到这个时间' : '按这个时间预约'),
        ),
      ],
    );
    return action;
  }

  Future<void> _bookAt(
    CapacityCandidate candidate,
    CapacityWindow window,
  ) async {
    final action = await _confirmBooking(candidate, window);
    if (action == null || !mounted) return;
    final append = action == _BookingAction.append;
    final item = candidate.item;
    int commitId;
    try {
      commitId = (await AppScope.of(context).study.capacity.book(
        item: item,
        start: window.start,
        end: window.end,
        append: append,
        expectedBlockId: candidate.movableBlockId,
        expectedBlockStart: candidate.movableStart,
        expectedBlockEnd: candidate.movableEnd,
        expectedNone:
            candidate.movableBlockId == null && candidate.scheduledMinutes == 0,
      )).commitId;
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: append ? '追加一段预约' : '按空档预约',
          kind: 'capacity_book',
          kept: '这次没有写入',
          next: '可以换一个空档再试',
        ),
      );
      return;
    }
    if (!mounted) return;
    showActionToast(
      context,
      append ? '已为「${item.title}」追加一段预约' : '已预约「${item.title}」',
      label: '撤销',
      onPressed: () => undoCommitWithFeedback(context, commitId, reload: _load),
    );
    setState(() {
      _loading = true;
      _plan = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final plan = _plan;
    final movable = <CapacityCandidate>[
      if (plan != null)
        for (final candidate in plan.candidates)
          if (candidate.movableStart != null && candidate.movableEnd != null)
            candidate,
    ];
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: _loading
          ? const SizedBox(
              height: 240,
              child: Center(child: forui.FCircularProgress()),
            )
          : plan == null
          ? _failureView(theme)
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('这周还能做什么', style: theme.text.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '本周剩余 ${plan.days} 天${plan.availableBudget}可用，'
                    '待排事项${plan.demandBudget}。',
                    style: theme.text.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '估时来自事项填写，未填写时按 20 分钟占位；'
                    '空档按截止时间算好后直接列出，点一段并确认新建或改约后，'
                    '才写入这个时间。',
                    style: theme.text.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '常用学习时段：${plan.windowStart}–${plan.windowEnd}',
                          style: theme.text.bodyMedium,
                        ),
                      ),
                      forui.FButton(
                        variant: forui.FButtonVariant.ghost,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _editWindow,
                        child: const Text('修改'),
                      ),
                    ],
                  ),
                  for (final note in plan.notes)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        note,
                        style: theme.text.bodySmall.copyWith(
                          color: theme.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (movable.isNotEmpty) ...[
                    Text('这次估算会把以下弹性预约算作可调整', style: theme.text.titleSmall),
                    for (final candidate in movable)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '「${candidate.item.title}」'
                          '${_rangeText(candidate.movableStart!, candidate.movableEnd!)}'
                          '；点它的空档后才改期',
                          style: theme.text.bodySmall,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('没有点选的预约保持原时间。', style: theme.text.bodySmall),
                    ),
                  ],
                  if (plan.candidates.isEmpty)
                    Text('当前没有可预约的学习事项。', style: theme.text.bodyMedium)
                  else
                    Text('按优先级与截止排出的顺序', style: theme.text.titleSmall),
                  for (var index = 0; index < plan.candidates.length; index++)
                    _candidateTile(theme, plan.candidates[index], index),
                  if (plan.skipped.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('本次不调整的安排', style: theme.text.titleSmall),
                    for (final skip in plan.skipped)
                      forui.FTile(
                        prefix: const Icon(FLucideIcons.lock),
                        title: Text(skip.item.title),
                        subtitle: Text(skip.reason),
                      ),
                  ],
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _notice!,
                        style: TextStyle(color: theme.colors.error),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      forui.FButton(
                        variant: forui.FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _loading
                            ? null
                            : () {
                                setState(() {
                                  _loading = true;
                                  _plan = null;
                                });
                                _load();
                              },
                        child: const Text('重新估算'),
                      ),
                      const SizedBox(width: 8),
                      forui.FButton(
                        mainAxisSize: MainAxisSize.min,
                        onPress: _loading
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _failureView(ZhixinTheme theme) => SizedBox(
    height: 240,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _notice ?? '暂时无法计算可用时间。',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colors.error),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () {
                setState(() {
                  _loading = true;
                  _notice = null;
                });
                _load();
              },
              child: const Text('重试'),
            ),
            forui.FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _candidateTile(
    ZhixinTheme theme,
    CapacityCandidate candidate,
    int index,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        forui.FTile(
          prefix: Text('${index + 1}.', style: theme.text.labelLarge),
          title: Text(candidate.item.title),
          subtitle: Text(_candidateText(candidate)),
        ),
        if (candidate.windows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final window in candidate.windows)
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _bookAt(candidate, window),
                    // FButton 的内容放在 Row 里，长时段文字不会自动换行，
                    // 加 Flexible 才能像原来的按钮一样在窄屏折行。
                    child: Flexible(child: Text(_windowText(window))),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _windowText(CapacityWindow window) =>
      '${dayLabel(window.start)} ${clockOf(window.start)}–${clockOf(window.end)}';

  String _rangeText(DateTime start, DateTime end) {
    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final endText = sameDay ? clockOf(end) : '${dayLabel(end)} ${clockOf(end)}';
    return '${dayLabel(start)} ${clockOf(start)}–$endText';
  }

  String _candidateText(CapacityCandidate candidate) {
    final estimate = candidate.hasEstimate
        ? '预计 ${candidate.minutes + candidate.scheduledMinutes} 分钟'
        : '未估时 · 暂按 ${candidate.minutes + candidate.scheduledMinutes} 分钟';
    final scheduled = candidate.scheduledMinutes == 0
        ? ''
        : ' · 已排 ${candidate.scheduledMinutes} 分钟';
    final planned = candidate.plannedMinutes;
    final status = planned == 0
        ? '截止时间前没有空档'
        : candidate.withinBudget
        ? '可完整做完'
        : '先做 $planned 分钟 · 还差 ${candidate.minutes - planned} 分钟';
    final existing = candidate.movableBlockId == null ? '' : ' · 预约时调整原时间';
    return '$estimate$scheduled · $status$existing';
  }
}
