import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../domain/models/study.dart';
import '../domain/models/time_values.dart';
import '../domain/rules/text.dart';
import 'date_time_dialogs.dart';
import 'copy.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'theme.dart';
import 'zhixin_dialog.dart';
import 'zhixin_select.dart';

class ItemDraft {
  const ItemDraft({
    required this.title,
    this.goalId,
    this.note,
    this.dueAt,
    this.minutes,
  });

  final String title;
  final String? goalId;

  /// 一句话说明这次做什么、做到什么程度算完成。
  final String? note;
  final DateTime? dueAt;
  final int? minutes;
}

class ItemDialog extends StatefulWidget {
  const ItemDialog({super.key, required this.goals});

  final List<LearningGoal> goals;

  @override
  State<ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<ItemDialog> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _minutes = TextEditingController();
  GoalChoice _goal = GoalChoice.unassigned;
  DateTime? _due;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: const Text('新建学习事项'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(
              controller: _title,
              onChange: (_) => setState(() {}),
            ),
            label: const Text('事项名称'),
          ),
          SizedBox(height: theme.space.gap),
          ZhixinSelect<GoalChoice>(
            value: _goal,
            label: goalSelectLabel,
            options: goalChoiceOptions(widget.goals),
            onChange: (value) =>
                setState(() => _goal = value ?? GoalChoice.unassigned),
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _note),
            minLines: 1,
            maxLines: 3,
            label: const Text('说明（可选）'),
            hint: '合上笔记重做第 8 题，写清放缩依据',
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _minutes),
            keyboardType: TextInputType.number,
            label: const Text('预计时长（分钟，可选）'),
          ),
          SizedBox(height: theme.space.gap),
          // 截止日期与新建目标用同一套写法：选中之后回显日期，旁边可以清除。
          Row(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () async {
                  final now = AppScope.of(context).timePolicy.now;
                  final picked = await showZhixinDatePicker(
                    context: context,
                    initialDate: _due ?? now,
                    firstDate: now,
                    lastDate: DateTime(now.year + 10, now.month, now.day),
                  );
                  if (context.mounted && picked != null) {
                    setState(() => _due = picked);
                  }
                },
                child: Text(_due == null ? '选择截止日期（可选）' : dateText(_due)),
              ),
              if (_due != null)
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(() => _due = null),
                  child: const Text('清除日期'),
                ),
            ],
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _title.text.trim().isEmpty
              ? null
              : () {
                  Navigator.of(context).pop(
                    ItemDraft(
                      title: _title.text.trim(),
                      goalId: _goal.goalId,
                      note: nullableText(_note.text),
                      dueAt: _due,
                      minutes: int.tryParse(_minutes.text.trim()),
                    ),
                  );
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class BlockDraft {
  const BlockDraft({
    required this.itemId,
    required this.start,
    required this.minutes,
  });

  final String itemId;
  final DateTime start;
  final int minutes;
}

class BlockDialog extends StatefulWidget {
  const BlockDialog({
    super.key,
    required this.items,
    this.initialItemId,
    this.initialStart,
    this.initialMinutes,
  });

  final List<PlanItem> items;
  final String? initialItemId;

  /// 改期时带入当前时间与时长，预约新时间时为空。
  final DateTime? initialStart;
  final int? initialMinutes;

  @override
  State<BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<BlockDialog> {
  late String _itemId = _initialItem();
  late DateTime _start;
  late int _minutes = widget.initialMinutes ?? 20;
  bool _timeInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timeInitialized) return;
    _timeInitialized = true;
    final now = AppScope.of(context).timePolicy.now;
    final initial = widget.initialStart;
    // 很早以前的预约改期时从当前时间重新选，避免日期选择器的初始日期越界。
    _start =
        initial == null ||
            initial.isBefore(now.subtract(const Duration(days: 1))) ||
            initial.isAfter(DateTime(now.year + 10, now.month, now.day))
        ? _roundToHalfHour(now)
        : initial;
  }

  String _initialItem() {
    final id = widget.initialItemId;
    return id != null && widget.items.any((item) => item.id == id)
        ? id
        : widget.items.first.id;
  }

  static DateTime _roundToHalfHour(DateTime now) {
    final minute = now.minute < 30 ? 30 : 0;
    final hour = now.minute < 30 ? now.hour : now.hour + 1;
    return DateTime(now.year, now.month, now.day, hour, minute);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final minuteOptions = {10, 20, 30, 45, _minutes}.toList()..sort();
    return ZhixinDialogLayout(
      title: Text(widget.initialStart == null ? '预约学习时间' : '改约学习时间'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ZhixinSelect<String>(
            value: _itemId,
            label: planItemName,
            options: {for (final item in widget.items) item.id: item.title},
            onChange: (value) {
              if (value != null) setState(() => _itemId = value);
            },
          ),
          SizedBox(height: theme.space.gap),
          // 时间按钮与时长下拉各带自己的标签，读者不必从内容猜这一格是什么。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('开始时间', style: theme.text.labelLarge),
                    SizedBox(height: theme.space.xs),
                    forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () async {
                        final now = AppScope.of(context).timePolicy.now;
                        final date = await showZhixinDatePicker(
                          context: context,
                          initialDate: _start,
                          firstDate: now.subtract(const Duration(days: 1)),
                          lastDate: DateTime(now.year + 10, now.month, now.day),
                        );
                        if (date == null) return;
                        if (!context.mounted) return;
                        final time = await showZhixinTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(_start),
                        );
                        if (!context.mounted) return;
                        final clock = time ?? TimeOfDay.fromDateTime(_start);
                        setState(() {
                          _start = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            clock.hour,
                            clock.minute,
                          );
                        });
                      },
                      // 日期不是今天时这一串会比按钮的可用宽度长：按可用宽度
                      // 缩小显示，不让按钮内部的 Row 溢出。
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(shortTime(_start)),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: theme.space.md),
              Expanded(
                child: ZhixinSelect<int>(
                  value: _minutes,
                  label: '时长',
                  options: {
                    for (final minutes in minuteOptions) minutes: '$minutes 分钟',
                  },
                  onChange: (value) {
                    if (value != null) setState(() => _minutes = value);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(
            context,
          ).pop(BlockDraft(itemId: _itemId, start: _start, minutes: _minutes)),
          child: const Text('预约'),
        ),
      ],
    );
  }
}

class TimetableDraft {
  const TimetableDraft({
    required this.weekday,
    required this.start,
    required this.end,
    required this.title,
    this.location,
  });

  final int weekday;
  final String start;
  final String end;
  final String title;
  final String? location;
}

class TimetableDialog extends StatefulWidget {
  const TimetableDialog({super.key});

  @override
  State<TimetableDialog> createState() => _TimetableDialogState();
}

class _TimetableDialogState extends State<TimetableDialog> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  late int _weekday;
  bool _weekdayInitialized = false;
  TimeOfDay _start = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 9, minute: 40);

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_weekdayInitialized) return;
    _weekdayInitialized = true;
    _weekday = AppScope.of(context).timePolicy.now.weekday;
  }

  String _clock(TimeOfDay time) => ClockTime(time.hour, time.minute).format();

  /// 结束时间不晚于开始时间时这一节课没有长度，保存按钮直接禁用。
  bool get _endNotAfterStart =>
      _end.hour * 60 + _end.minute <= _start.hour * 60 + _start.minute;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final canSave = _title.text.trim().isNotEmpty && !_endNotAfterStart;
    return ZhixinDialogLayout(
      title: const Text('添加课表'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(
              controller: _title,
              onChange: (_) => setState(() {}),
            ),
            label: const Text('课程名称'),
          ),
          SizedBox(height: theme.space.gap),
          ZhixinSelect<int>(
            value: _weekday,
            label: '星期',
            options: {
              for (var day = 1; day <= 7; day++) day: weekdayLabel(day),
            },
            onChange: (value) {
              if (value != null) setState(() => _weekday = value);
            },
          ),
          SizedBox(height: theme.space.gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _clockField(theme, '开始时间', _start, true)),
              SizedBox(width: theme.space.md),
              Expanded(child: _clockField(theme, '结束时间', _end, false)),
            ],
          ),
          if (_endNotAfterStart)
            Padding(
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '结束时间要晚于开始时间。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.error,
                  ),
                ),
              ),
            ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _location),
            label: const Text('地点（可选）'),
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: canSave
              ? () {
                  Navigator.of(context).pop(
                    TimetableDraft(
                      weekday: _weekday,
                      start: _clock(_start),
                      end: _clock(_end),
                      title: _title.text.trim(),
                      location: nullableText(_location.text),
                    ),
                  );
                }
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 一节课的开始或结束：上面写字段名，下面按 24 小时制显示并可以点开重选。
  Widget _clockField(
    ZhixinTheme theme,
    String label,
    TimeOfDay value,
    bool isStart,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.text.labelLarge),
        SizedBox(height: theme.space.xs),
        forui.FButton(
          variant: forui.FButtonVariant.outline,
          mainAxisSize: MainAxisSize.min,
          onPress: () async {
            final time = await showZhixinTimePicker(
              context: context,
              initialTime: value,
              helpText: label,
            );
            if (!mounted || time == null) return;
            setState(() {
              if (isStart) {
                _start = time;
              } else {
                _end = time;
              }
            });
          },
          child: Text(_clock(value)),
        ),
      ],
    );
  }
}
