import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../domain/models/study.dart';
import 'date_time_dialogs.dart';
import 'format.dart';
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
  final int? goalId;

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
  int _goalId = 0;
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
    return ZhixinDialogLayout(
      title: const Text('新建学习事项'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(controller: _title),
            label: const Text('事项名称'),
          ),
          const SizedBox(height: 8),
          ZhixinSelect<int>(
            value: _goalId,
            label: '目标（可选）',
            options: {
              0: '单独记录',
              for (final goal in widget.goals) goal.id: goal.title,
            },
            onChange: (value) => setState(() => _goalId = value ?? 0),
          ),
          const SizedBox(height: 8),
          forui.FTextField(
            control: .managed(controller: _note),
            minLines: 1,
            maxLines: 3,
            label: const Text('说明（可选）'),
            hint: '合上笔记重做第 8 题，写清放缩依据',
          ),
          const SizedBox(height: 8),
          forui.FTextField(
            control: .managed(controller: _minutes),
            keyboardType: TextInputType.number,
            label: const Text('预计时长（分钟，可选）'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () async {
                  final now = AppScope.of(context).timePolicy.now;
                  final picked = await showZhixinDatePicker(
                    context: context,
                    initialDate: now,
                    firstDate: now.subtract(const Duration(days: 1)),
                    lastDate: DateTime(now.year + 10, now.month, now.day),
                  );
                  if (context.mounted && picked != null) {
                    setState(() => _due = picked);
                  }
                },
                child: Text(_due == null ? '选截止日期' : dateText(_due)),
              ),
            ],
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
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.of(context).pop(
              ItemDraft(
                title: title,
                goalId: _goalId == 0 ? null : _goalId,
                note: _note.text.trim().isEmpty ? null : _note.text.trim(),
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

  final int itemId;
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
  final int? initialItemId;

  /// 改期时带入当前时间与时长，预约新时间时为空。
  final DateTime? initialStart;
  final int? initialMinutes;

  @override
  State<BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<BlockDialog> {
  late int _itemId = _initialItem();
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

  int _initialItem() {
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
    final minuteOptions = {10, 20, 30, 45, _minutes}.toList()..sort();
    return ZhixinDialogLayout(
      title: Text(widget.initialStart == null ? '预约学习时间' : '改约学习时间'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ZhixinSelect<int>(
            value: _itemId,
            label: '学习事项',
            options: {for (final item in widget.items) item.id: item.title},
            onChange: (value) {
              if (value != null) setState(() => _itemId = value);
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
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
                child: Text(shortTime(_start)),
              ),
              SizedBox(
                width: 128,
                child: ZhixinSelect<int>(
                  value: _minutes,
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
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
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

  String _clock(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ZhixinDialogLayout(
      title: const Text('添加课表'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(controller: _title),
            label: const Text('课程名称'),
          ),
          const SizedBox(height: 8),
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
          Row(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () async {
                  final time = await showZhixinTimePicker(
                    context: context,
                    initialTime: _start,
                  );
                  if (context.mounted && time != null) {
                    setState(() => _start = time);
                  }
                },
                child: Text('开始 ${_clock(_start)}'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () async {
                  final time = await showZhixinTimePicker(
                    context: context,
                    initialTime: _end,
                  );
                  if (context.mounted && time != null) {
                    setState(() => _end = time);
                  }
                },
                child: Text('结束 ${_clock(_end)}'),
              ),
            ],
          ),
          forui.FTextField(
            control: .managed(controller: _location),
            label: const Text('地点（可选）'),
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
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.of(context).pop(
              TimetableDraft(
                weekday: _weekday,
                start: _clock(_start),
                end: _clock(_end),
                title: title,
                location: _location.text.trim().isEmpty
                    ? null
                    : _location.text.trim(),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
