import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'zhixin_dialog.dart';

/// 云端历史已经压缩、本机要用快照重建之前的确认（改进方案 3.7）。
///
/// 返回 true 表示用户同意用云端快照替换本机的数据版本历史；取消或关闭都返回
/// false，调用方据此不同步，本机数据保持不变（重建不会静默执行）。
Future<bool> confirmSnapshotRebuild(
  BuildContext context, {
  required int localCommits,
}) {
  return confirmZhixin(
    context: context,
    title: '云端历史已经压缩，这台设备要从云端快照重建',
    content: Text(
      '继续之后会用云端快照替换本机的数据版本历史：撤销窗口、命名版本与更早的'
      '提交按快照重建，本机还没有推送的 $localCommits 条改动会作为新提交重放到'
      '快照之上，其他登录这个账号的设备看到的内容不变。取消则不同步，本机数据'
      '保持不变。',
    ),
    confirmLabel: '按快照重建',
  );
}

/// 首次把本机记录上传到某个账号之前的确认。
///
/// 返回 true 表示用户同意上传；取消或关闭都返回 false，调用方据此不上传并
/// 暂停自动同步。
Future<bool> confirmBaselineUpload(
  BuildContext context, {
  required int localCommits,
}) {
  return confirmZhixin(
    context: context,
    title: '首次同步会把本机记录合并到账号',
    content: Text(
      '这个账号还没有同步过。继续之后会先拉取云端已有的记录，只把本机独有、云端'
      '还没有的记录作为基线上传，本机现在有 $localCommits 条提交；其他登录这个'
      '账号的设备也会看到这些记录。取消则不上传，并暂停自动同步。',
    ),
    confirmLabel: '上传并同步',
  );
}

/// 暂停之后恢复自动同步之前的确认：写清楚会把本机记录同步到哪个账号。
Future<bool> confirmEnableAutoSync(
  BuildContext context, {
  required String accountLabel,
}) {
  return confirmZhixin(
    context: context,
    title: '开启自动同步',
    content: Text(
      '开启之后，本机写入会在后台推送到${accountLabel.isEmpty ? '当前账号' : ' $accountLabel 对应的账号'}；'
      '这个账号第一次同步时会先拉取云端已有的记录，只补传云端还没有的记录，届时还会再确认一次。',
    ),
    confirmLabel: '开启',
  );
}

/// 整库恢复之后的重新对齐：说明云端会改成恢复后的内容。
///
/// 返回 true 表示用户同意把恢复后的内容同步到云端；取消或关闭都返回 false，
/// 调用方据此不同步，恢复后的内容仍留在本机，下一次点“立即同步”会再问。
Future<bool> confirmRestoreAlignment(BuildContext context) {
  return confirmZhixin(
    context: context,
    title: '同步会把云端改成恢复后的内容',
    content: Text(
      '本机刚刚恢复过一份旧备份。继续之后会把恢复后的内容同步到这个账号的云端，'
      '恢复之前推送的多余记录会从云端删除，其他登录这个账号的设备也会看到恢复后的内容。'
      '取消则不同步，恢复后的内容仍留在本机。',
    ),
    confirmLabel: '同步并覆盖云端',
  );
}

/// 摘要不一致时“以云端为准修复”之前的确认（改进方案 3.5）。
///
/// 返回 true 表示用户同意按云端重新对齐；取消或关闭都返回 false，调用方据此
/// 不做修复，本机与云端的状态保持原样。
Future<bool> confirmRepairFromCloud(BuildContext context) {
  return confirmZhixin(
    context: context,
    title: '以云端为准修复会重做这台设备的同步',
    content: Text(
      '修复会清掉这台设备的同步位置，重新从云端拉取全部提交，再按首次同步的方式'
      '把本机独有的记录补传上去。本机被直接改过、没有提交记录表达的部分会被云端'
      '内容覆盖；云端已有的记录不会删除。取消则不做修复，两边内容保持原样。',
    ),
    confirmLabel: '以云端为准修复',
  );
}

/// 摘要不一致时“以本机为准修复”之前的确认（改进方案 3.5）。
///
/// 返回 true 表示用户同意把本机独有的记录补传到云端；取消或关闭都返回 false。
/// 这个入口只补传、不删除云端已有的内容，确认框里要说明云端多出来的记录不会
/// 因此消失，避免用户把它理解成两边内容会被强行改成一致（ADR-0045）。
Future<bool> confirmRepairFromLocal(BuildContext context) {
  return confirmZhixin(
    context: context,
    title: '以本机为准修复会补传云端缺少的记录',
    content: Text(
      '修复会先拉取云端的新提交并应用到本机，同一处内容与云端不同时按云端为准，'
      '然后把云端没有的本机记录作为基线补传上去。云端已有的记录不会删除，所以'
      '云端多出来的内容不会因此消失，需要的话在仍有这些记录的设备上删除；'
      '取消则不做修复。',
    ),
    confirmLabel: '以本机为准修复',
  );
}

/// 改设备别名的输入框：去掉首尾空白后 0–64 个字符，留空表示清除（ADR-0048）。
///
/// 返回输入的原样文本，由调用方去掉首尾空白后提交；取消或关闭返回 null。
Future<String?> promptDeviceAlias(
  BuildContext context, {
  String currentAlias = '',
}) => showZhixinDialog<String>(
  context: context,
  builder: (context) => _DeviceAliasDialog(currentAlias: currentAlias),
);

class _DeviceAliasDialog extends StatefulWidget {
  const _DeviceAliasDialog({required this.currentAlias});

  final String currentAlias;

  @override
  State<_DeviceAliasDialog> createState() => _DeviceAliasDialogState();
}

class _DeviceAliasDialogState extends State<_DeviceAliasDialog> {
  late final TextEditingController _alias = TextEditingController(
    text: widget.currentAlias,
  );

  @override
  void dispose() {
    _alias.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_alias.text);

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: const Text('设备改名'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('别名用来在提交来源与设备列表里区分这台设备，不影响同步，也不改写已经推送的记录。'),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _alias),
            autofocus: true,
            maxLength: 64,
            label: const Text('设备名'),
            description: const Text('0–64 个字符，留空表示清除别名。'),
            onSubmit: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
