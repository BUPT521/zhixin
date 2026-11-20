import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/prefetch_service.dart';
import '../data/cloud/server_client.dart';
import 'account_dialogs.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'navigation.dart';
import 'restore_flow.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_toast.dart';
import 'workspace_widgets.dart';

/// 云端备份：列出这个账号在服务端保存的整库备份，上传当前版本库，下载后恢复到本机。
///
/// 服务端每份备份是“备份版本库”生成的 zip，保留最近若干份；恢复走本机已有的
/// 预检、确认与恢复点流程，下载的字节与文件包一样先校验再替换（ADR-0008 第一步）。
class CloudBackupPage extends StatefulWidget {
  const CloudBackupPage({super.key});

  @override
  State<CloudBackupPage> createState() => _CloudBackupPageState();
}

class _CloudBackupPageState extends State<CloudBackupPage> {
  List<ServerBackup>? _backups;
  bool _signedIn = false;
  bool _loading = true;
  bool _busy = false;
  String? _notice;
  bool _failed = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 进入“我的”时已经在后台读过一次列表；先用这一份，读完再刷新。
    final prewarm = AppScope.of(context).prefetch
        .take<List<ServerBackup>>(PrefetchKey.cloudBackups);
    if (prewarm != null) {
      _backups = prewarm;
      _signedIn = true;
      _loading = false;
    }
    _load();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      final snapshot = await scope.accountServices.account.snapshot();
      if (!snapshot.signedIn) {
        if (!mounted) return;
        setState(() {
          _signedIn = false;
          _loading = false;
        });
        return;
      }
      final backups = await scope.accountServices.backups.list();
      if (!mounted) return;
      setState(() {
        _signedIn = true;
        _backups = backups;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取云端备份',
          kind: 'cloud_backup_list',
          kept: '本机记录与云端备份没有改动',
          next: '可以检查网络与服务地址后重试',
        );
        _failed = true;
      });
    }
  }

  void _report(String message, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _failed = failed;
    });
  }

  Future<void> _upload() async {
    if (_busy) return;
    setState(() => _busy = true);
    _report('正在生成并上传版本库备份…');
    try {
      final backup = await AppScope.of(context).accountServices.backups
          .upload();
      _report(
        '已上传备份：${_sizeLabel(backup.size)}'
        '${backup.createdAt == null ? '' : '，${shortTime(backup.createdAt!)}'}',
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '上传云端备份',
          kind: 'cloud_backup_upload',
          kept: '本机数据与已有备份没有改动',
          next: '可以检查网络后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(ServerBackup backup) async {
    if (_busy) return;
    setState(() => _busy = true);
    _report('正在下载云端备份…');
    try {
      final bytes = await AppScope.of(context).accountServices.backups
          .download(backup.id);
      if (!mounted) return;
      _report('正在校验云端备份…');
      final message = await runPackageRestore(
        context,
        preset: bytes,
        origin:
            '云端备份（${backup.createdAt == null ? '时间未知' : shortTime(backup.createdAt!)}'
            '${backup.deviceName.isEmpty ? '' : '，${backup.deviceName}'}）',
        onStatus: (status) => _report(status),
      );
      if (!mounted) return;
      if (message != null) showToast(context, message);
      _notice = null;
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '从云端备份恢复',
          kind: 'cloud_backup_restore',
          kept: '当前数据保留',
          next: '可以重新选择另一份备份',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ServerBackup backup) async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除云端备份',
      content: const Text('删除之后不能再从这份备份恢复；本机记录与其他备份不受影响。'),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.backups.delete(backup.id);
      _report('已删除这份云端备份');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '删除云端备份',
          kind: 'cloud_backup_delete',
          kept: '云端备份还在',
          next: '可以再试一次',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAll() async {
    final password = await askDestructiveActionPassword(
      context,
      title: '删除全部云端备份',
      message: '会永久删除这个账号在服务端保存的全部整库备份，账号与同步序列会保留。',
      confirmLabel: '全部删除',
    );
    if (password == null || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.backups
          .deleteAll(password: password);
      _report('已删除全部云端备份');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '删除全部云端备份',
          kind: 'cloud_backup_delete_all',
          kept: '云端备份没有改动',
          next: '可以检查网络后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('云端备份'), showBack: true),
      // 首读期间保留标题栏，内容用与卡片同高的骨架占位。
      child: _loading
          ? ListView(
              padding: theme.space.pageInsets(bottom: 96),
              children: const [ListSkeleton(rows: 3, rowHeight: 96)],
            )
          : _signedIn
          ? _content(context)
          : _signedOut(context),
    );
  }

  Widget _signedOut(BuildContext context) {
    final theme = context.zhixin;
    return ListView(
      padding: theme.space.pageInsets(bottom: 96),
      children: [
        SectionHeading(
          title: '需要登录',
          first: true,
          subtitle: '云端备份按账号保存；登录之后可以上传整库快照，换机时下载恢复。',
        ),
        InlineNotice(message: _notice ?? '还没有登录，云端备份与同步都不可用。'),
        Align(
          alignment: Alignment.centerLeft,
          child: forui.FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: () => openAccount(context),
            child: const Text('去登录'),
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context) {
    final theme = context.zhixin;
    final backups = _backups ?? const <ServerBackup>[];
    return ListView(
      padding: theme.space.pageInsets(bottom: 96),
      children: [
        SectionHeading(
          title: '整库快照',
          first: true,
          subtitle: '备份包含提交历史、命名版本与附件；上传新的一份时服务端只保留最近几份。',
          action: backups.isEmpty
              ? null
              : forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _deleteAll,
                  child: const Text('全部删除'),
                ),
        ),
        if (_notice != null)
          _failed
              ? InlineNotice(message: _notice!, onRetry: _busy ? null : _load)
              : Padding(
                  padding: EdgeInsets.only(bottom: theme.space.sm),
                  child: Text(_notice!, style: theme.text.bodySmall),
                ),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _busy
                      ? '正在处理，请稍候…'
                      : '把当前这台设备的版本库上传到云端，'
                            '换手机或重装之后登录即可下载恢复。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: theme.space.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: forui.FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : _upload,
                    prefix: const Icon(FLucideIcons.cloudUpload),
                    child: Text(backups.isEmpty ? '上传当前版本库' : '再上传一份备份'),
                  ),
                ),
              ],
            ),
          ),
        ),
        SectionHeading(
          title: '云端备份',
          subtitle: backups.isEmpty
              ? '服务端还没有这个账号的备份。'
              : '新的在前，共 ${backups.length} 份。',
        ),
        if (backups.isEmpty)
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.cloud, tone: TagTone.muted),
            title: const Text('还没有云端备份'),
            subtitle: const Text('上传之后这里会按时间列出，可以下载恢复或删除。'),
          )
        else
          for (final backup in backups)
            Padding(
              padding: EdgeInsets.only(top: theme.space.tight),
              child: forui.FTile(
                prefix: const LeadingIcon(FLucideIcons.cloud),
                title: Text(
                  backup.createdAt == null
                      ? '时间未知'
                      : shortTime(backup.createdAt!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_sizeLabel(backup.size)}'
                  '${backup.deviceName.isEmpty ? '' : ' · ${backup.deviceName}'}'
                  ' · schema ${backup.schemaVersion}',
                ),
                suffix: moreMenu(
                  items: [
                    ZhixinMenuItem(
                      label: '下载并恢复',
                      onSelected: _busy ? null : () => _restore(backup),
                    ),
                    ZhixinMenuItem(
                      label: '删除这份备份',
                      onSelected: _busy ? null : () => _delete(backup),
                    ),
                  ],
                ),
              ),
            ),
        SizedBox(height: theme.space.md),
        Text(
          '下载恢复会先预检包内 HEAD、历史与附件，再让你确认；恢复前自动保存一份本机恢复点。',
          style: theme.text.bodySmall,
        ),
      ],
    );
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
