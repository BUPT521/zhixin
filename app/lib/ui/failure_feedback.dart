import 'package:flutter/widgets.dart';

import '../app_scope.dart';
import '../application/failure_notice.dart';
import '../domain/models/result.dart';

/// 把一次本地失败写进本机诊断记录，并返回界面上的说明。
///
/// 页面只显示返回值；异常类型、消息与调用栈留在诊断记录里，排障时再看。调用
/// 方应先在异步回调里确认 `mounted`，避免在已经离开的页面上读取应用作用域。
String describeFailure(
  BuildContext context,
  Object error,
  StackTrace stack, {
  required String action,
  required String kind,
  String? kept,
  String? next,
}) {
  AppScope.of(context).crashLog.record(error, stack, kind: kind);
  return failureNotice(error, action: action, kept: kept, next: next);
}

/// 结果已经给出失败原因时，补上保留状态与下一步，并写进本机诊断记录。
///
/// [FailureReason.message] 已经是给用户看的说明，不再套“某一步没有完成”；
/// 诊断记录用当前调用位置代替已经丢失的原始调用栈。
String describeFailureReason(
  BuildContext context,
  FailureReason reason, {
  required String kind,
  String? kept,
  String? next,
}) {
  AppScope.of(context).crashLog.record(reason, StackTrace.current, kind: kind);
  final detail = [
    if (kept != null && kept.trim().isNotEmpty) kept.trim(),
    if (next != null && next.trim().isNotEmpty) next.trim(),
  ].join('。');
  final message = reason.message.replaceFirst(RegExp(r'。$'), '');
  return detail.isEmpty ? '$message。' : '$message，$detail。';
}
