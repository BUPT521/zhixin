import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'failure_feedback.dart';
import 'zhixin_toast.dart';

/// 撤销一条提交：读出撤销结果、提示用户，再让调用方重读自己的列表。
///
/// 安排、讨论、记忆与材料页原先各写一遍这段流程，提示文字与刷新时机容易分叉。
/// 写入方现在都返回提交编号，撤销只走这一条路径，是否还能撤销由提交服务按同一
/// 套规则判断。
///
/// [onUndone] 在撤销成功、重读列表之前回调；材料页用它先关掉仍开着的更正面板。
Future<void> undoCommitWithFeedback(
  BuildContext context,
  int commitId, {
  required Future<void> Function() reload,
  VoidCallback? onUndone,
}) async {
  final revisions = AppScope.of(context).revisions;
  try {
    final result = await revisions.undoCommit(commitId);
    onUndone?.call();
    if (context.mounted) showToast(context, result.message);
    await reload();
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
