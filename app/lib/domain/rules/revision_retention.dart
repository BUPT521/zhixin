/// 默认保留天数：最近这么多天的提交全部保留，覆盖撤销与回执的使用窗口。
///
/// 保留口径是“时间优先”（方案 3.8，G9，对照 `git gc --auto`）：时间窗口里的
/// 提交不受容量预算影响，更早的提交才按历史字节预算裁剪。
const int revisionDefaultRetentionDays = 14;

/// 数据版本页可以选择的保留天数；设置值与默认值都落在这个范围里。
const List<int> revisionRetentionDayOptions = [7, 14, 30, 60, 90, 180];
