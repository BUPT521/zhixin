/// 一周七天的中文名；课表、冲突说明、日期标题与计划页共用这一份。
library;

const List<String> weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// [weekday] 按 [DateTime.weekday] 取值，周一为 1；超出范围时返回空串。
String weekdayLabel(int weekday) =>
    weekday >= 1 && weekday <= weekdayNames.length
    ? weekdayNames[weekday - 1]
    : '';
