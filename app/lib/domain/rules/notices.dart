/// 提示文案的拼接规则：两条都非空时用空格接起来，空值不占位置。
///
/// 讨论、作答与回退回答原先各写一份 `_joinNotices`；这里只统一拼接方式，
/// 具体文案仍由各自的业务场景给出。
String? joinNotices(String? first, String? second) {
  final left = first?.trim();
  final right = second?.trim();
  final hasLeft = left != null && left.isNotEmpty;
  final hasRight = right != null && right.isNotEmpty;
  if (hasLeft && hasRight) return '$left $right';
  if (hasLeft) return left;
  if (hasRight) return right;
  return null;
}
