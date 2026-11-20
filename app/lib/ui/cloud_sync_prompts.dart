import 'package:material_ui/material_ui.dart';

import 'zhixin_dialog.dart';

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
