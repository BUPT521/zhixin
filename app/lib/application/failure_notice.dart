import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../data/cloud/server_client.dart';
import '../data/repository/schedule_repository.dart';
import '../data/revisions/revision_engine.dart';
import '../domain/models/backup_error.dart';
import '../domain/models/material.dart';
import 'account_service.dart';
import 'sync_service.dart';

/// 本地读写失败时给界面看的一句说明。
///
/// 说明只回答三件事：哪一步没有完成、已经有的内容是否还在、接下来可以做什么。
/// 异常原文不进入界面，由本机诊断记录保存排障所需的类型、消息与调用栈。已经是
/// 给人看的领域错误保留原说明，再补上保留状态与下一步，避免把“已有原文”或
/// “时段冲突”退化成一句笼统的失败；模型调用只取按类型归类的一句，不把配置、
/// 响应体或密钥带出来。
String failureNotice(
  Object error, {
  required String action,
  String? kept,
  String? next,
}) {
  final known = _knownMessage(error)?.replaceFirst(RegExp(r'。$'), '');
  final suffix = [
    if (kept != null && kept.trim().isNotEmpty) kept.trim(),
    if (next != null && next.trim().isNotEmpty) next.trim(),
  ].join('。');
  if (known != null) {
    return suffix.isEmpty ? known : '$known，$suffix。';
  }
  final head = '$action没有完成';
  return suffix.isEmpty ? '$head。' : '$head，$suffix。';
}

/// 已经是给人看的错误，直接保留它的说法；其余异常由调用方按动作改写。
String? _knownMessage(Object error) => switch (error) {
  BackupException(:final message) => message,
  ScheduleConflictException() => error.toString(),
  PageNumberTaken() => error.toString(),
  RevisionStaleHead() => error.toString(),
  LlmException(:final shortText) => '模型调用失败（$shortText）',
  LlmConfigReadFailure() => '读取模型配置失败',
  ServerProblem(:final userMessage) => userMessage,
  AccountSignedOut(:final userMessage) => userMessage,
  AccountConfigException(:final message) => message,
  SyncSchemaMismatch() => error.toString(),
  SyncIdentityChanged() => error.toString(),
  // 同步侧这几类都带着已经写给人看的说明：快照重建要确认、历史压缩缺快照、
  // 快照字节对不上、首次基线要确认；落到通用兜底会把“接下来能做什么”丢掉
  // （ADR-0046）。
  BaselineConfirmationRequired(:final message) => message,
  SyncHistoryCompacted(:final userMessage) => userMessage,
  SyncSnapshotProblem(:final message) => message,
  _ => null,
};
