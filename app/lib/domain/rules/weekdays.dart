/// 一周七天的中文名；课表、搭子和日期标题共用一份。
library;

const List<String> weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String weekdayLabel(int weekday) => weekdayNames[weekday - 1];
