import 'package:calendar_view/calendar_view.dart';
import 'package:flutter/material.dart'
    as flutter_material
    show Material, MaterialType;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../domain/models/study.dart';

/// 安排页展开后的周视图：把这一周的预约与固定课表换算成日历事件。
///
/// 组件只接收已经读好的数据和回调：事件控制器由它创建、按新数据更新并在
/// 卸载时释放，换周读取、写入与页面跳转都留在调用方。展开与收起由调用方
/// 决定是否把它放进树里；横滑翻周与点击事件通过回调报告用户操作。
class PlanWeekView extends StatefulWidget {
  const PlanWeekView({
    super.key,
    required this.weekStart,
    required this.blocks,
    required this.timetable,
    required this.onWeekSelected,
    required this.onBlockTap,
    required this.onTimetableTap,
  });

  /// 当前这一周的周一；日历标题与事件日期都以它为准。
  final DateTime weekStart;

  /// 这一周已加载的预约，按开始时间排列。
  final List<ScheduledItem> blocks;

  /// 固定课表；组件按 [weekStart] 把它们展开成这一周的事件。
  final List<TimetableEntry> timetable;

  /// 用户横滑到另一周时报告那一周的周一。
  final ValueChanged<DateTime> onWeekSelected;

  /// 用户点击一段预约。
  final ValueChanged<ScheduledItem> onBlockTap;

  /// 用户点击一节课。
  final ValueChanged<TimetableEntry> onTimetableTap;

  @override
  State<PlanWeekView> createState() => _PlanWeekViewState();
}

class _PlanWeekViewState extends State<PlanWeekView> {
  /// 事件控制器跟着组件走：换一次数据只替换事件，不再每次构建都新建一个。
  final EventController<Object> _controller = EventController<Object>();
  final GlobalKey<WeekViewState<Object>> _calendarKey =
      GlobalKey<WeekViewState<Object>>();

  /// 上一次同步事件时用到的输入；颜色变了也要跟着换。
  Object? _eventInputs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncEvents();
  }

  @override
  void didUpdateWidget(covariant PlanWeekView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncEvents();
    if (!_sameWeek(oldWidget.weekStart, widget.weekStart)) {
      _showWeek();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 按收到的周数据重建事件；输入没有变化时不动控制器。
  void _syncEvents() {
    final theme = context.zhixin;
    final inputs = (
      widget.weekStart,
      widget.blocks,
      widget.timetable,
      theme.colors.primary,
      theme.colors.outlineVariant,
    );
    if (inputs == _eventInputs) return;
    _eventInputs = inputs;

    final events = <CalendarEventData<Object>>[
      for (final entry in widget.blocks) _blockEvent(entry, theme),
      for (final entry in widget.timetable) ..._timetableEvents(entry, theme),
    ];
    _controller.clear();
    _controller.addAll(events);
  }

  CalendarEventData<Object> _blockEvent(
    ScheduledItem entry,
    ZhixinTheme theme,
  ) {
    final start = entry.block.startAt;
    final end = entry.block.endAt;
    return CalendarEventData<Object>(
      date: DateTime(start.year, start.month, start.day),
      startTime: start,
      endTime: end,
      title: entry.itemTitle,
      color: theme.colors.primary,
      event: entry,
    );
  }

  List<CalendarEventData<Object>> _timetableEvents(
    TimetableEntry entry,
    ZhixinTheme theme,
  ) {
    final events = <CalendarEventData<Object>>[];
    for (var offset = 0; offset < 7; offset++) {
      final day = DateTime(
        widget.weekStart.year,
        widget.weekStart.month,
        widget.weekStart.day + offset,
      );
      if (day.weekday != entry.weekday) continue;
      final start = _atTime(day, entry.startTime);
      final end = _atTime(day, entry.endTime);
      if (start == null || end == null || !end.isAfter(start)) continue;
      events.add(
        CalendarEventData<Object>(
          date: DateTime(day.year, day.month, day.day),
          startTime: start,
          endTime: end,
          title: entry.title,
          color: theme.colors.outlineVariant,
          event: entry,
        ),
      );
    }
    return events;
  }

  /// 新的周数据回来之后把日历翻到那一周；已经在那一周时不动。
  void _showWeek() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final calendar = _calendarKey.currentState;
      if (calendar == null) return;
      if (_sameWeek(calendar.currentDate, widget.weekStart)) return;
      calendar.jumpToWeek(widget.weekStart);
    });
  }

  /// 翻页回调：日历自己翻到已加载的周时不再报告，避免又发起一次读取。
  void _handlePageChange(DateTime date) {
    if (_sameWeek(date, widget.weekStart)) return;
    widget.onWeekSelected(date);
  }

  void _handleEventTap(List<CalendarEventData<Object>> events) {
    final event = events.firstOrNull?.event;
    if (event is ScheduledItem) {
      widget.onBlockTap(event);
      return;
    }
    if (event is TimetableEntry) widget.onTimetableTap(event);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Container(
      height: 420,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: theme.radius.card,
        border: Border.all(color: theme.colors.outlineVariant),
      ),
      child: flutter_material.Material(
        type: flutter_material.MaterialType.transparency,
        child: WeekView<Object>(
          key: _calendarKey,
          controller: _controller,
          initialDay: widget.weekStart,
          startHour: 6,
          endHour: 24,
          heightPerMinute: 0.55,
          showVerticalLines: true,
          weekPageHeaderBuilder: (start, end) => const SizedBox.shrink(),
          weekDayStringBuilder: (index) {
            const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
            return index >= 1 && index <= 7 ? labels[index - 1] : '';
          },
          timeLineStringBuilder: (date, {secondaryDate}) => '${date.hour}:00',
          onPageChange: (date, _) => _handlePageChange(date),
          onEventTap: (events, _) => _handleEventTap(events),
        ),
      ),
    );
  }

  static bool _sameWeek(DateTime left, DateTime right) =>
      left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;

  static DateTime? _atTime(DateTime day, String text) {
    final parts = text.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return DateTime(day.year, day.month, day.day, hour, minute);
  }
}
