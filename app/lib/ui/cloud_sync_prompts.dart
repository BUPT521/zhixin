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
    title: '首次同步会把本机记录上传到账号',
    content: Text(
      '这个账号还没有同步过。继续之后会把本机现有的 $localCommits 条提交作为基线'
      '完整上传到这个账号的云端，其他登录这个账号的设备也会看到这些记录。'
      '取消则不上传，并暂停自动同步。',
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
      '这个账号第一次同步时会先把本机现有的记录作为基线上传，届时还会再确认一次。',
    ),
    confirmLabel: '开启',
  );
}
