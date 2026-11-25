import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../application/account_service.dart';
import 'format.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';

Future<bool?> editZhixinServerAddress(
  BuildContext context, {
  required String serverBaseUrl,
  required Future<void> Function(String address) onSave,
}) => showZhixinDialog<bool>(
  context: context,
  builder: (_) =>
      _ServerAddressDialog(serverBaseUrl: serverBaseUrl, onSave: onSave),
);

class _ServerAddressDialog extends StatefulWidget {
  const _ServerAddressDialog({
    required this.serverBaseUrl,
    required this.onSave,
  });

  final String serverBaseUrl;
  final Future<void> Function(String address) onSave;

  @override
  State<_ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<_ServerAddressDialog> {
  late final _address = TextEditingController(text: widget.serverBaseUrl);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_address.text.trim().isEmpty) {
      setState(() => _error = '请输入知新服务地址');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_address.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (error) {
          AccountConfigException() => error.message,
          FormatException() => error.message,
          _ => '无法确认该地址运行着兼容的知新服务，请核对地址和服务状态',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: ZhixinDialogLayout(
      title: const Text('知新服务地址'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          forui.FTextField(
            control: .managed(controller: _address),
            label: const Text('实例地址'),
            keyboardType: TextInputType.url,
            enabled: !_saving,
            description: const Text('请填写知新实例的 HTTPS 地址。切换实例后需要重新登录。'),
            onSubmit: (_) => _save(),
          ),
          if (_error case final error?) InlineNotice(message: error),
        ],
      ),
      actions: [
        if (!_saving) cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _saving ? null : _save,
          child: Text(_saving ? '正在核对实例…' : '保存地址'),
        ),
      ],
    ),
  );
}

/// 删除账号前的重新认证：先读一遍删除范围，再输入当前密码。
///
/// 服务端要求删除账号时重新提交密码，因此账号页不再只做一次“确定/取消”。
/// 返回输入的密码；取消返回 null。密码留空时留在对话框里提示，不关闭。
///
/// [remainingPoints] 是删除之前读到的积分余额；即刻收一侧按账号标识记账，删号
/// 之后这份余额无人可用，所以有余额时在删除范围之后单独提示一句。余额未知时
/// 传 null，不显示这一句。
Future<String?> askDeleteAccountPassword(
  BuildContext context, {
  int? remainingPoints,
}) {
  final points = remainingPoints ?? 0;
  final message =
      '会删除这个账号在服务端保存的备份、同步序列、附件与登录会话，且无法恢复。'
      '这个账号的本机空间也会删除。请先导出需要保留的数据包，之后可以在本机空间导入。';
  final pointsNotice = points > 0
      ? '这个账号还有 ${groupDigits(points)} 积分，删除之后无法使用，也无法退款。'
      : '';
  return askDestructiveActionPassword(
    context,
    title: '删除账号',
    message: pointsNotice.isEmpty ? message : '$message\n\n$pointsNotice',
    confirmLabel: '删除账号',
  );
}

Future<String?> askDestructiveActionPassword(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) {
  return showZhixinDialog<String>(
    context: context,
    builder: (context) => _PasswordConfirmationDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
  );
}

class _PasswordConfirmationDialog extends StatefulWidget {
  const _PasswordConfirmationDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_PasswordConfirmationDialog> createState() =>
      _PasswordConfirmationDialogState();
}

class _PasswordConfirmationDialogState
    extends State<_PasswordConfirmationDialog> {
  final _password = TextEditingController();
  bool _missing = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _password.text;
    if (value.isEmpty) {
      setState(() => _missing = true);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: Text(widget.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _password),
            obscureText: true,
            autofocus: true,
            label: const Text('当前密码'),
            description: const Text('请输入当前密码确认操作。'),
            onSubmit: (_) => _submit(),
          ),
          if (_missing) ...[
            SizedBox(height: theme.space.sm),
            Text(
              '填写当前密码后再删除',
              style: theme.text.bodySmall.copyWith(color: theme.colors.error),
            ),
          ],
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          variant: forui.FButtonVariant.destructive,
          mainAxisSize: MainAxisSize.min,
          onPress: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
