/// 需要按稳定值读写的枚举的统一形态。
///
/// [value] 写进库、数据包与结构化字段，[label] 是界面可显示的说法。读回时由
/// 共用的查找函数处理，各枚举不再各写一份回落逻辑；未知值如何回落由调用方
/// 通过 [unknown] 给出。
abstract interface class CodedEnum {
  String get value;
  String get label;
}

/// 按稳定值读回枚举；认不出的值与空值返回空，由调用方决定是否使用未知值。
T? codedValueOrNull<T extends CodedEnum>(Iterable<T> values, String? value) {
  if (value == null) return null;
  for (final candidate in values) {
    if (candidate.value == value) return candidate;
  }
  return null;
}

/// 按稳定值读回枚举；认不出的值与空值回落到 [unknown]。
T codedValueOr<T extends CodedEnum>(
  Iterable<T> values,
  String? value, {
  required T unknown,
}) => codedValueOrNull(values, value) ?? unknown;
