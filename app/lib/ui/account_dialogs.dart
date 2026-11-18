import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'zhixin_dialog.dart';

/// 删除账号前的重新认证：先读一遍删除范围，再输入当前密码。
///
/// 服务端要求删除账号时重新提交密码，因此账号页不再只做一次“确定/取消”。
/// 返回输入的密码；取消返回 null。密码留空时留在对话框里提示，不关闭。
Future<String?> askDeleteAccountPassword(BuildContext context) {
  return showZhixinDialog<String>(
    context: context,
    builder: (context) => const _DeleteAccountDialog(),
  );
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
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
      title: const Text('删除账号'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '会删除这个账号在服务端保存的备份、同步序列、附件与登录会话，且无法恢复；'
            '本机学习记录不受影响。删除之后可以用同一个邮箱重新注册。',
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _password),
            obscureText: true,
            autofocus: true,
            label: const Text('当前密码'),
            description: const Text('确认是账号本人在操作；密码错误时账号与登录状态都不改动。'),
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
          child: const Text('删除账号'),
        ),
      ],
    );
  }
}
