/// 数据版本提交里表示界面回执的动作名称。
///
/// 讨论里的记忆写入、确认记忆与接受下一步建议会在提交历史里留下可撤销的
/// 回执，安排页按这三个动作挑出“AI 的改动”。材料页更正单独登记，撤销时
/// 据此开放更正提交里的材料行更新时间。名称同时是写进提交的说明，改动这里
/// 要同步全部写入点，否则回执会从对应页面消失。
const String writeMemoryAction = '写入记忆';
const String confirmMemoryAction = '确认记忆';
const String acceptNextStepAction = '接受下一步建议';

/// 作答里的记忆建议经用户点“记下”写入；同一条提交还改尝试上的帮助，撤销时
/// 记忆删除、建议回到待确认。
const String confirmAttemptMemoryAction = '确认作答记忆';

/// 材料页更正；撤销这个动作时还允许回写材料行的更新时间。
const String correctMaterialPageAction = '更正材料页';

/// 记忆页的手工写入；与讨论里的 AI 记忆动作分开，不进入安排页的“AI 的改动”。
/// 删除是软删除，撤销时按反向规则把状态改回 active。
const String addMemoryAction = '新增记忆';
const String editMemoryAction = '修改记忆';
const String deleteMemoryAction = '删除记忆';

/// 设置页修改每日截止小时；提交只更新 `profile` 一行。撤销之后界面与
/// 时间口径要重新读取，不能继续用启动时缓存的截止小时。
const String changeCutoffHourAction = '修改每日截止小时';

/// 清理或裁剪历史之后，消息里指向已删除提交的回执由这条提交统一去掉；
/// 它改的是派生数据，不能反过来撤销，否则会把失效编号装回消息。
const String clearDeadReceiptsAction = '清理失效回执';

/// 安排页展示的可撤销动作。
const Set<String> receiptActions = {
  writeMemoryAction,
  confirmMemoryAction,
  confirmAttemptMemoryAction,
  acceptNextStepAction,
};
