import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/sync_service.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'navigation.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'workspace_widgets.dart';

/// 账号与云同步：服务地址、登录注册、同步状态与云端数据操作。
///
/// 账号是可选项：不登录时应用完全在本机运行；登录之后才开启云端备份、按提交
/// 的增量同步与“知新服务”模型来源（ADR-0008）。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  AccountSnapshot? _snapshot;
  SyncStatus? _sync;
  bool _loading = true;
  bool _busy = false;

  /// 页面顶部的一次性说明：失败用就地说明，成功用一行小字。
  String? _notice;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_snapshot == null && _loading) _load();
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      final snapshot = await scope.accountServices.account.snapshot();
      final sync = await scope.accountServices.sync.status();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _sync = sync;
        _server.text = snapshot.serverBaseUrl;
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
          action: '读取账号状态',
          kind: 'account_load',
          kept: '本机记录与登录状态没有改动',
          next: '可以稍后再试',
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

  Future<void> _saveServer() async {
    final scope = AppScope.of(context);
    try {
      final value = _server.text.trim();
      if (value.isEmpty) {
        _report('先填写服务地址，例如 https://zhixin.example.com', failed: true);
        return;
      }
      await scope.accountServices.account.setServerBaseUrl(value);
      _report('服务地址已保存');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '保存服务地址',
          kind: 'account_server',
          kept: '原来的地址没有改动',
          next: '地址只填域名或完整的 https 地址',
        ),
        failed: true,
      );
    }
  }

  Future<void> _submit({required bool register}) async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      _report('填写邮箱与密码后再继续', failed: true);
      return;
    }
    if (password.length < 8) {
      _report('密码至少 8 位', failed: true);
      return;
    }
    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      if (_server.text.trim().isNotEmpty) {
        await scope.accountServices.account.setServerBaseUrl(_server.text);
      }
      final account = scope.accountServices.account;
      final result = register
          ? await account.register(email: email, password: password)
          : await account.login(email: email, password: password);
      _password.clear();
      await scope.accountServices.sync.schedule(
        delay: const Duration(seconds: 1),
      );
      _report(
        '${register ? '注册并登录' : '登录'}成功：${result.email}；'
        '云端备份与知新服务已经可用，同步会在后台开始',
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: register ? '注册' : '登录',
          kind: 'account_login',
          kept: '本机记录没有改动',
          next: '可以检查邮箱、密码与服务地址后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await AppScope.of(context).accountServices.sync.syncNow();
      _report(
        result.changed
            ? '同步完成：拉取 ${result.pulledCommits} 条、推送 ${result.pushedCommits} 条提交，'
                  '上传 ${result.uploadedAssets}、下载 ${result.downloadedAssets} 个附件'
            : '同步完成，本机与云端已经一致',
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '同步',
          kind: 'account_sync',
          kept: '本机记录没有改动，已经同步的部分保留',
          next: '可以检查网络后重试',
        ),
        failed: true,
      );
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.account.logout();
      _report('已退出登录；本机记录仍在，云端数据保留');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '退出登录',
          kind: 'account_logout',
          kept: '登录状态没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCloudData() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '清除云端数据',
      content: const Text(
        '会删除这个账号在服务端保存的全部整库备份与同步提交序列，'
        '本机学习记录和账号保留。之后的下一次同步会把当前本机数据重新上传为基线；'
        '其他设备需要重新同步，删除后无法恢复。',
      ),
      confirmLabel: '清除',
      destructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final scope = AppScope.of(context);
      await scope.accountServices.account.clearCloudData();
      await scope.accountServices.sync.clearState();
      _report('云端备份与同步序列已清除；下一次同步会从本机重新开始');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '清除云端数据',
          kind: 'account_clear_cloud',
          kept: '云端数据与本机记录没有改动',
          next: '可以检查网络后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除账号',
      content: const Text(
        '会删除这个账号在服务端保存的备份、同步序列、附件与登录会话，且无法恢复；'
        '本机学习记录不受影响。删除之后可以用同一个邮箱重新注册。',
      ),
      confirmLabel: '删除账号',
      destructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final scope = AppScope.of(context);
      await scope.accountServices.account.deleteAccount();
      await scope.accountServices.sync.clearState();
      _report('账号与云端数据已删除；本机记录仍在');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '删除账号',
          kind: 'account_delete',
          kept: '账号与云端数据没有改动',
          next: '可以检查网络后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAutoSync(bool value) async {
    try {
      await AppScope.of(context).accountServices.account.setAutoSync(value);
      if (!mounted) return;
      setState(
        () => _snapshot = AccountSnapshot(
          serverBaseUrl: _snapshot?.serverBaseUrl ?? '',
          session: _snapshot?.session,
          autoSync: value,
        ),
      );
      if (value) {
        await AppScope.of(context).accountServices.sync
            .schedule(delay: const Duration(seconds: 1));
      }
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '保存自动同步设置',
          kind: 'account_autosync',
          kept: '自动同步保持原样',
          next: '可以再试一次',
        ),
        failed: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('账号与云同步'), showBack: true),
      child: _loading ? const PageLoading() : _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final theme = context.zhixin;
    final snapshot = _snapshot;
    final signedIn = snapshot?.signedIn ?? false;
    return ListView(
      padding: theme.space.pageInsets(bottom: 96),
      children: [
        if (_notice != null)
          _failed
              ? InlineNotice(message: _notice!)
              : Padding(
                  padding: EdgeInsets.only(bottom: theme.space.md),
                  child: Text(_notice!, style: theme.text.bodySmall),
                ),
        if (!signedIn) ..._loggedOut(context),
        if (signedIn) ..._loggedIn(context, snapshot!),
        SizedBox(height: theme.space.md),
        Text(
          '学习记录默认保存在本机，登录之后才会使用服务端的备份、同步与模型代理；'
          '调用模型时只发送当次所需内容。令牌只保存在这台设备的 Keystore 里。',
          style: theme.text.bodySmall,
        ),
      ],
    );
  }

  List<Widget> _loggedOut(BuildContext context) {
    final theme = context.zhixin;
    return [
      SectionHeading(
        title: '服务地址',
        first: true,
        subtitle: '由项目组提供；地址、账号与密码只用于这台设备登录，不写进仓库。',
        action: StatusTag(
          _snapshot?.serverBaseUrl.isNotEmpty == true ? '已填写' : '未填写',
          tone: _snapshot?.serverBaseUrl.isNotEmpty == true
              ? TagTone.accent
              : TagTone.muted,
        ),
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              forui.FTextField(
                control: .managed(controller: _server),
                label: const Text('服务地址'),
                hint: 'https://zhixin.example.com',
                description: const Text(
                  '只填域名时按 https 处理；本地联调可以填 http://127.0.0.1:8080。',
                ),
              ),
              SizedBox(height: theme.space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: forui.FButton(
                  variant: forui.FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _saveServer,
                  child: const Text('保存地址'),
                ),
              ),
            ],
          ),
        ),
      ),
      SectionHeading(
        title: '登录或注册',
        subtitle: '登录之后可以上传整库备份、在多台设备之间同步，并使用知新服务的模型额度。',
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              forui.FTextField(
                control: .managed(controller: _email),
                keyboardType: TextInputType.emailAddress,
                label: const Text('邮箱'),
              ),
              SizedBox(height: theme.space.gap),
              forui.FTextField(
                control: .managed(controller: _password),
                obscureText: true,
                label: const Text('密码（至少 8 位）'),
              ),
              SizedBox(height: theme.space.md),
              Wrap(
                spacing: theme.space.sm,
                runSpacing: theme.space.sm,
                children: [
                  forui.FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : () => _submit(register: false),
                    child: const Text('登录'),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : () => _submit(register: true),
                    child: const Text('注册'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _loggedIn(BuildContext context, AccountSnapshot snapshot) {
    final theme = context.zhixin;
    final sync = _sync;
    return [
      SectionHeading(
        title: '账号',
        first: true,
        subtitle: '一个账号对应一个人的学习数据；退出登录不删除云端数据。',
        action: const StatusTag('已登录', tone: TagTone.accent),
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(snapshot.email, style: theme.text.titleMedium),
              SizedBox(height: theme.space.xs),
              Text(
                snapshot.serverLabel,
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.sm),
              forui.FSwitch(
                label: const Text('自动同步'),
                description: const Text('写入之后在后台推送；关闭后只在上面的“立即同步”里执行。'),
                value: snapshot.autoSync,
                onChange: _busy ? null : _setAutoSync,
              ),
            ],
          ),
        ),
      ),
      SectionHeading(
        title: '同步',
        subtitle: '服务端保存同一条提交序列的另一份；两台设备同时修改同一字段时后到达的覆盖先到达的。',
        action: StatusTag(
          sync?.syncing == true
              ? '同步中'
              : (sync?.lastError == null ? '空闲' : '上次失败'),
          tone: sync?.lastError == null ? TagTone.muted : TagTone.attention,
        ),
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_syncSummary(sync), style: theme.text.bodyMedium),
              if (sync?.lastError != null) ...[
                SizedBox(height: theme.space.sm),
                InlineNotice(
                  message: sync!.lastError!,
                  onRetry: _busy ? null : _syncNow,
                ),
              ],
              SizedBox(height: theme.space.md),
              Wrap(
                spacing: theme.space.sm,
                runSpacing: theme.space.sm,
                children: [
                  forui.FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy || sync?.syncing == true ? null : _syncNow,
                    prefix: const Icon(FLucideIcons.refreshCw),
                    child: const Text('立即同步'),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : () => openCloudBackup(context),
                    child: const Text('云端备份'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      SectionHeading(
        title: '云端数据',
        subtitle: '删除账号会一并删除云端记录；清除云端数据只删备份与同步序列，本机记录和账号保留。',
      ),
      forui.FTile(
        variant: forui.FItemVariant.destructive,
        prefix: const LeadingIcon(FLucideIcons.cloudOff, tone: TagTone.muted),
        title: const Text('清除云端数据'),
        subtitle: const Text('删除云端备份与同步序列，之后从本机重新同步。'),
        suffix: const Icon(FLucideIcons.trash2),
        onPress: _busy ? null : _clearCloudData,
      ),
      SizedBox(height: theme.space.sm),
      forui.FTile(
        variant: forui.FItemVariant.destructive,
        prefix: const LeadingIcon(FLucideIcons.userX, tone: TagTone.muted),
        title: const Text('删除账号'),
        subtitle: const Text('删除账号与全部云端数据；本机学习记录保留。'),
        suffix: const Icon(FLucideIcons.trash2),
        onPress: _busy ? null : _deleteAccount,
      ),
      SizedBox(height: theme.space.md),
      forui.FTile(
        prefix: const LeadingIcon(FLucideIcons.logOut),
        title: const Text('退出登录'),
        subtitle: const Text('退出这台设备；云端数据保留，下次登录可以继续同步。'),
        suffix: const Icon(FLucideIcons.chevronRight),
        onPress: _busy ? null : _logout,
      ),
    ];
  }

  String _syncSummary(SyncStatus? sync) {
    if (sync == null) return '同步状态暂时无法读取。';
    if (!sync.signedIn) return '还没有登录。';
    final last = sync.lastSyncedAt;
    final lastText = last == null ? '还没有同步过' : '上次同步 ${shortTime(last)}';
    final serverHead = sync.serverHead;
    return '$lastText · 本机 HEAD ${sync.localHead}'
        '${serverHead == null ? '' : ' · 服务端位置 $serverHead'}'
        ' · 待同步 ${sync.needsBootstrap ? '首次基线' : '${sync.pendingCommits} 条提交'}';
  }
}
