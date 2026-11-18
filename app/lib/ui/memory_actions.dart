import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../domain/models/memory.dart';
import 'date_time_dialogs.dart';
import 'failure_feedback.dart';
import 'memory_dialog.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'zhixin_toast.dart';

/// 记忆页与记忆查找页共用的写入入口：新增、修改、恢复、删除与撤销回执。
///
/// 两个页面都按同一套提交与撤销规则写入，弹窗、确认框与提示条只在这里排一次，
/// 避免查找页另写一份之后提示文字或撤销行为分叉。函数返回是否真的写入，页面
/// 据此决定要不要重新读取自己的结果。

/// 记一条新记忆；保存成功之后提示条带“撤销”。
Future<bool> addMemory(
  BuildContext context, {
  Future<void> Function()? reload,
}) async {
  final draft = await showZhixinDialog<MemoryDraft>(
    context: context,
    builder: (_) => const MemoryDialog(),
  );
  if (draft == null || !context.mounted) return false;
  try {
    final result = await AppScope.of(context).memory.edit.add(
      kind: draft.kind,
      content: draft.content,
      validUntil: draft.validUntil,
    );
    if (!context.mounted || !result.changed) return false;
    showMemoryReceipt(context, '已记下这条记忆', result.commitId!, reload: reload);
    return true;
  } catch (error, stack) {
    if (!context.mounted) return false;
    showToast(
      context,
      describeFailure(
        context,
        error,
        stack,
        action: '保存这条记忆',
        kind: 'memory_add',
        kept: '记忆没有写入',
        next: '可以再试一次',
      ),
    );
    return false;
  }
}

/// 修改一条记忆；内容与类型没有变化时只提示没有变化，不形成提交。
Future<bool> editMemory(
  BuildContext context,
  Memory memory, {
  Future<void> Function()? reload,
}) async {
  final draft = await showZhixinDialog<MemoryDraft>(
    context: context,
    builder: (_) => MemoryDialog(memory: memory),
  );
  if (draft == null || !context.mounted) return false;
  try {
    final result = await AppScope.of(context).memory.edit.save(
      memory,
      kind: draft.kind,
      content: draft.content,
      validUntil: draft.validUntil,
    );
    if (!context.mounted) return false;
    if (!result.changed) {
      showToast(context, result.skippedReason ?? '这条记忆没有变化。');
      return false;
    }
    showMemoryReceipt(context, '已修改这条记忆', result.commitId!, reload: reload);
    return true;
  } catch (error, stack) {
    if (!context.mounted) return false;
    showToast(
      context,
      describeFailure(
        context,
        error,
        stack,
        action: '修改这条记忆',
        kind: 'memory_edit',
        kept: '记忆仍是修改前的内容',
        next: '可以再试一次',
      ),
    );
    return false;
  }
}

/// 过期条目恢复：选一个新的有效期，写回之后重新参与检索。
Future<bool> restoreMemory(
  BuildContext context,
  Memory memory, {
  Future<void> Function()? reload,
}) async {
  final now = AppScope.of(context).timePolicy.now;
  final picked = await showZhixinDatePicker(
    context: context,
    initialDate: now,
    firstDate: now,
    lastDate: DateTime(now.year + 10, now.month, now.day),
  );
  if (picked == null || !context.mounted) return false;
  try {
    final result = await AppScope.of(context).memory.edit.save(
      memory,
      kind: memory.kind,
      content: memory.content,
      validUntil: picked,
    );
    if (!context.mounted) return false;
    if (!result.changed) {
      showToast(context, result.skippedReason ?? '这条记忆没有变化。');
      return false;
    }
    showMemoryReceipt(context, '已恢复这条记忆', result.commitId!, reload: reload);
    return true;
  } catch (error, stack) {
    if (!context.mounted) return false;
    showToast(
      context,
      describeFailure(
        context,
        error,
        stack,
        action: '恢复这条记忆',
        kind: 'memory_restore',
        kept: '这条记忆仍是过期的状态',
        next: '可以再试一次',
      ),
    );
    return false;
  }
}

/// 删除一条记忆：先说明会影响哪些建议，确认之后软删除并给出撤销。
Future<bool> deleteMemory(
  BuildContext context,
  Memory memory,
  Map<String, String> scopeLabels, {
  Future<void> Function()? reload,
}) async {
  final confirmed = await confirmZhixin(
    context: context,
    title: '删除这条记忆',
    content: Text(
      '${memoryDeleteImpact(memory, scopeLabels)}“${memory.content}”',
    ),
    confirmLabel: '删除',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return false;
  try {
    final result = await AppScope.of(context).memory.edit.delete(memory.id);
    if (!context.mounted || !result.changed) return false;
    showMemoryReceipt(context, '已删除这条记忆', result.commitId!, reload: reload);
    return true;
  } catch (error, stack) {
    if (!context.mounted) return false;
    showToast(
      context,
      describeFailure(
        context,
        error,
        stack,
        action: '删除这条记忆',
        kind: 'memory_delete',
        kept: '这条记忆还在',
        next: '可以再试一次',
      ),
    );
    return false;
  }
}

/// 删除前说明会影响哪些建议：按类型说清不再被参考的内容，按范围说清影响面。
String memoryDeleteImpact(Memory memory, Map<String, String> scopeLabels) {
  final scope = memory.scope;
  final place = scope == null ? '全部学习里' : '「${scopeLabels[scope] ?? '范围已删除'}」下';
  final effect = switch (memory.kind) {
    MemoryKind.preference => '讲解与建议不再参考这条偏好',
    MemoryKind.constraint => '回答不再按这条限制安排',
    MemoryKind.difficulty => '讲解不再针对这类困难',
    MemoryKind.progress => '安排不再参考这条进展',
    MemoryKind.unknown => '后续回答不再使用这条记忆',
  };
  return '删除后，$place的$effect。';
}

/// 保存、删除与恢复的提示条指向各自提交；撤销按反向规则写回。
///
/// [reload] 给按次查询的页面使用：撤销成功之后重新取一次自己的结果；订阅中
/// 的记忆页不需要它。
void showMemoryReceipt(
  BuildContext context,
  String message,
  int commitId, {
  Future<void> Function()? reload,
}) {
  showActionToast(
    context,
    message,
    label: '撤销',
    onPressed: () => undoCommitWithFeedback(context, commitId, reload: reload),
  );
}
