import '../../data/revisions/revision_models.dart';

/// 撤销之后这一行的值：当前行再加上目标提交记下的旧值。
///
/// 净变化只保存改动过的列，`updated_at` 这类维护列在撤销核对里被忽略，因此
/// 判断恢复后的时间与依赖时要把当前行与旧值拼起来，不能用当前行或旧值单方
/// 代替。各 guard 共用这一份拼法，避免规则之间出现不同的解释。
TypedRow mergedUndoRow(TypedRow current, TypedRow before) => {
  ...current,
  for (final entry in before.entries) entry.key: entry.value,
};
