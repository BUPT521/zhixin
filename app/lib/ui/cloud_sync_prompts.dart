import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../application/sync_flow.dart';
import 'theme.dart';
import 'zhixin_dialog.dart';

/// 同步过程中要用户确认的一次：按种类弹对应的确认框。
///
/// 账号页与“我的”页把这一份当作 [SyncFlow.run] 的确认回调，两个页面的确认顺序、
/// 确认框与文案因此只有一处（A22）。
Future<bool> confirmSyncStep(
  BuildContext context,
  SyncConfirmation confirmation,
) => switch (confirmation) {
  SyncRestoreAlignment() => confirmRestoreAlignment(context),
  SyncBaselineUpload(:final localCommits) => confirmBaselineUpload(
    context,
    localCommits: localCommits,
  ),
  SyncSnapshotRebuild(:final localCommits) => confirmSnapshotRebuild(
    context,
    localCommits: localCommits,
  ),
};

/// 一轮同步结束之后的说明：完成写提交与附件数量，取消写下一步。
///
/// 账号页原先多写附件数、取消说明也另说一句，“我的”页只说提交数，同一件事在
/// 两页读出两个结果；这里只写一份，两页共用（A22）。
String syncResultNotice(SyncFlowResult flow) => switch (flow.outcome) {
  SyncOutcome.cancelledRestoreAlignment => '已取消同步；恢复后的内容仍在本机，需要时可以再点“立即同步”',
  SyncOutcome.cancelledBaselineUpload => '已取消首次同步，没有上传本机记录；自动同步已暂停',
  SyncOutcome.cancelledSnapshotRebuild => '已取消同步；本机数据保持不变，需要时可以再点“立即同步”',
  SyncOutcome.completed => _completedNotice(flow),
};

String _completedNotice(SyncFlowResult flow) {
  final result = flow.result;
  if (result == null || !result.changed) {
    // 摘要不一致时不能声称两边已经一致：修复入口与说明在账号页的同步卡上。
    return flow.digestMismatch == true
        ? '同步完成；本机与云端的内容仍不一致，按上面的说明选择修复方式'
        : '同步完成，本机与云端已经一致';
  }
  final assets = result.uploadedAssets == 0 && result.downloadedAssets == 0
      ? ''
      : '，上传 ${result.uploadedAssets}、下载 ${result.downloadedAssets} 个附件';
  return '同步完成：拉取 ${result.pulledCommits} 条、'
      '推送 ${result.pushedCommits} 条提交$assets';
}

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
