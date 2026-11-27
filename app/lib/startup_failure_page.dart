import 'dart:io';

import 'package:flutter/services.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'application/feedback_service.dart';
import 'data/cloud/cloud_preferences_store.dart' show defaultServerBaseUrl;
import 'data/cloud/server_client.dart' show ServerProblem;
import 'data/diagnostics/crash_log.dart';
import 'platform/app_info.dart';

/// 启动装配失败时的页面：说明本机数据没有改动，并给出重试、发送诊断反馈与
/// 复制诊断信息三个入口。
///
/// 数据库打不开时页面与账号都不可用，反馈不能依赖应用根已经装配好的服务，
/// 因此这里自带一个最小的提交入口，服务地址取编译时的默认实例；诊断摘要沿用
/// 崩溃记录的脱敏说明，不含学习正文、文件路径与密钥。
class StartupFailurePage extends StatefulWidget {
  const StartupFailurePage({
    super.key,
    required this.error,
    required this.stack,
    required this.retrying,
    required this.onRetry,
    required this.diagnostics,
  });

  final Object error;
  final StackTrace? stack;
  final bool retrying;
  final Future<void> Function() onRetry;
  final String diagnostics;

  @override
  State<StartupFailurePage> createState() => _StartupFailurePageState();
}

class _StartupFailurePageState extends State<StartupFailurePage> {
  bool _sending = false;
  bool _copying = false;
  String? _status;
  bool _statusIsError = false;

  Future<void> _sendFeedback() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _status = null;
    });
    final service = FeedbackService(
      serverBaseUrl: () async => defaultServerBaseUrl,
    );
    try {
      final receipt = await service.submit(
        FeedbackDraft(
          content: '启动失败：本地数据库没有打开',
          appVersion: appVersion,
          diagnostics: widget.diagnostics,
        ),
      );
      if (!mounted) return;
      setState(() {
        _status = '反馈已提交，回执编号 ${receipt.id}。';
        _statusIsError = false;
      });
    } on ServerProblem catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.userMessage;
        _statusIsError = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = '反馈没有提交成功。请检查网络后再试，或者先复制诊断信息发给开发。';
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: widget.diagnostics));
      if (!mounted) return;
      setState(() {
        _status = '诊断信息已复制，可以粘贴到反馈正文里。';
        _statusIsError = false;
      });
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = CrashLog.describe(widget.error);
    return forui.FScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本地数据库没有打开', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
              '本机的学习记录没有改动。一般是数据目录或数据库文件暂时不可用，'
              '可以重试一次；重复失败时发送反馈，诊断信息随反馈一起提交。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text('错误：$reason', style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: widget.retrying ? null : widget.onRetry,
                  child: Text(widget.retrying ? '正在重试' : '重试打开'),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _sending ? null : _sendFeedback,
                  child: Text(_sending ? '正在提交' : '发送诊断反馈'),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _copyDiagnostics,
                  child: const Text('复制诊断信息'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 16),
              Text(
                _status!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _statusIsError
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 失败页复制与反馈用的诊断摘要：版本、平台、时间、错误和截断后的调用栈。
///
/// 与崩溃记录同一套脱敏说明，不含学习正文、文件路径与密钥。
String startupDiagnostics(Object error, StackTrace? stack) {
  final rawStack = (stack?.toString() ?? '').trim();
  final clipped = rawStack.length > 1500
      ? '${rawStack.substring(0, 1500)}\n（调用栈已截断）'
      : rawStack;
  return [
    '应用：知新 $appVersion',
    '平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    '时间：${DateTime.now().toIso8601String()}',
    '错误：${CrashLog.describe(error)}',
    '调用栈：${clipped.isEmpty ? '（无）' : clipped}',
  ].join('\n');
}
