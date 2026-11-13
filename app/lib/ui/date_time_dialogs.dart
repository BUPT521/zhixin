import 'package:material_ui/material_ui.dart';

/// 选择日期；范围与返回值都按天对齐，初始日期落进范围里再打开。
Future<DateTime?> showZhixinDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) async {
  final first = DateUtils.dateOnly(firstDate);
  final last = DateUtils.dateOnly(lastDate);
  final initial = DateUtils.dateOnly(initialDate);
  final selected = initial.isBefore(first)
      ? first
      : (initial.isAfter(last) ? last : initial);
  final picked = await showDatePicker(
    context: context,
    initialDate: selected,
    firstDate: first,
    lastDate: last,
    helpText: '选择日期',
    cancelText: '取消',
    confirmText: '确定',
  );
  return picked == null ? null : DateUtils.dateOnly(picked);
}

/// 选择时间；界面固定 24 小时制，与页面里的时刻写法一致。
Future<TimeOfDay?> showZhixinTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
}) {
  return showTimePicker(
    context: context,
    initialTime: initialTime,
    helpText: '选择时间',
    cancelText: '取消',
    confirmText: '确定',
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
}
