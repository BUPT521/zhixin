import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'failure_feedback.dart';
import 'zhixin_toast.dart';

/// 撤销一条提交：读出撤销结果、提示用户，必要时再让调用方重读自己的列表。
///
/// 安排、讨论、记忆与材料页原先各写一遍这段流程，提示文字与刷新时机容易分叉。
/// 写入方现在都返回提交编号，撤销只走这一条路径，是否还能撤销由提交服务按同一
/// 套规则判断。
///
/// 页面改成订阅之后，撤销写回的行会由数据层推给订阅，调用方不再需要重读，
/// [reload] 因此可以为空；[onUndone] 在撤销成功、重读之前回调，材料页用它先
/// 关掉仍开着的更正面板。
Future<void> undoCommitWithFeedback(
  BuildContext context,
  int commitId, {
  Future<void> Function()? reload,
  VoidCallback? onUndone,
}) async {
  final undo = AppScope.of(context).data.undo;
  try {
    final result = await undo.undoCommit(commitId);
    onUndone?.call();
    if (context.mounted) showToast(context, result.message);
    if (reload != null) await reload();
  } catch (error, stack) {
    if (!context.mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '撤销这次操作',
      kind: 'undo',
      kept: '原来的内容保持不变',
      next: '可以再试一次',
    );
    showToast(context, message);
  }
}
