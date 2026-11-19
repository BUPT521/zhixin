import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/prefetch_service.dart';
import '../application/sync_service.dart';
import '../data/cloud/server_client.dart' show ServerQuota;
import '../platform/app_info.dart';
import 'copy.dart';
import 'cloud_sync_prompts.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'navigation.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 底栏“我的”（02 第 2.1 节）：账号卡在最上，下面按数据、学习、通用分组列出
/// 次级入口。
///
/// 账号卡只放最常用的三件事：看登录与同步状态、立即同步、进账号页；登录、
/// 找回密码、删除账号这些完整操作仍在账号页。设置页只管偏好配置，记忆、人格、
/// 插件、数据版本与关于从这里进入。
class MinePage extends StatefulWidget {
  const MinePage({
    super.key,
    required this.activeTab,
    this.tabIndex = 3,
    this.preload,
  });

  final ValueListenable<int> activeTab;
  final int tabIndex;

  /// 底栏放行预读时为真：先在后台读本机的登录与同步状态，额度也一起读好，
  /// 第一次切过来账号卡已经就位，不再等网络。
  final ValueListenable<bool>? preload;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  AccountSnapshot? _account;
  SyncStatus? _sync;
  ServerQuota? _quota;

  /// 额度要走网络；读完本机状态先显示，额度回来再补上。
  bool _quotaLoading = false;

  /// 读取的序号：预读还没回来、切栏又发起了完整读取时，丢掉预读的结果。
  int _loadSequence = 0;
  bool _loaded = false;
  bool _syncing = false;

  /// 账号卡下方的一次性结果：失败用就地说明，成功用一行小字。
  String? _notice;
  bool _failed = false;

  bool get _active => widget.activeTab.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    widget.activeTab.addListener(_onActiveChanged);
    widget.preload?.addListener(_onPreload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 未显示的页面等底栏放行预读再读；切到“我的”时还没放行的，当场读。
    // 预读与切栏读同一份内容，额度也一起读好，切过来不再看到“正在读取”。
    if (!_loaded && (_active || (widget.preload?.value ?? false))) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant MinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTab != widget.activeTab) {
      oldWidget.activeTab.removeListener(_onActiveChanged);
      widget.activeTab.addListener(_onActiveChanged);
    }
    if (oldWidget.preload != widget.preload) {
      oldWidget.preload?.removeListener(_onPreload);
      widget.preload?.addListener(_onPreload);
    }
  }

  @override
  void dispose() {
    widget.activeTab.removeListener(_onActiveChanged);
    widget.preload?.removeListener(_onPreload);
    super.dispose();
  }

  /// 登录状态与同步状态没有订阅：每次切回这一栏都重读一次。
  void _onActiveChanged() {
    if (_active) _load();
  }

  /// 预读与切栏读同一份内容：登录状态、同步状态与今日额度一起读好。
  void _onPreload() {
    if (!mounted || _loaded || _active) return;
    if (widget.preload?.value ?? false) _load();
  }

  /// 读登录状态、同步状态与今日额度；后一次读取会丢掉前一次还没回来的结果。
  Future<void> _load() async {
    final scope = AppScope.of(context);
    final services = scope.accountServices;
    final sequence = ++_loadSequence;
    try {
      final account = await services.account.snapshot();
      final sync = await services.sync.status();
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _account = account;
        _sync = sync;
        _loaded = true;
        if (!account.signedIn) _quota = null;
        _quotaLoading = account.signedIn;
      });
      if (!account.signedIn) {
        // 账号页读的是同一份数据，留给它之后打开直接用。
        scope.prefetch.put(PrefetchKey.accountPage, (
          snapshot: account,
          sync: sync,
          quota: null,
        ));
        return;
      }
      ServerQuota? remaining;
      try {
        remaining = await services.account.quota();
      } catch (_) {
        // 额度只用于显示；读不到时写“暂时无法读取”，不打断其余内容。
      }
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _quota = remaining;
        _quotaLoading = false;
      });
      scope.prefetch.put(PrefetchKey.accountPage, (
        snapshot: account,
        sync: sync,
        quota: remaining,
      ));
    } catch (error, stack) {
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _loaded = true;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取账号状态',
          kind: 'mine_account_load',
          kept: '本机记录与登录状态没有改动',
          next: '可以切到别的页面再回来重试',
        );
        _failed = true;
      });
    }
  }

  /// 推入一页，回来之后重读登录与同步状态：账号页可能登录、退出或同步过。
  Future<void> _push(Future<void> Function(BuildContext) open) async {
    await open(context);
    if (!mounted) return;
    await _load();
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    final services = AppScope.of(context).accountServices;
    var confirmBaseline = false;
    try {
      final status = await services.sync.status();
      if (status.baselineNeedsConfirmation) {
        if (!mounted) return;
        final confirmed = await confirmBaselineUpload(
          context,
          localCommits: status.localHead,
        );
        if (!confirmed) {
          await services.account.setAutoSync(false);
          if (!mounted) return;
          setState(() {
            _failed = false;
            _notice = '已取消首次同步，没有上传本机记录；自动同步已暂停';
          });
          await _load();
          return;
        }
        confirmBaseline = true;
      }
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取同步状态',
          kind: 'mine_sync_status',
          kept: '本机记录没有改动',
          next: '可以稍后再试',
        );
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _syncing = true;
      _notice = null;
    });
    try {
      final result = await services.sync.syncNow(
        confirmBaseline: confirmBaseline,
      );
      if (!mounted) return;
      setState(() {
        _failed = false;
        _notice = result.changed
            ? '同步完成：拉取 ${result.pulledCommits} 条、推送 ${result.pushedCommits} 条提交'
            : '同步完成，本机与云端已经一致';
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '同步',
          kind: 'mine_sync',
          kept: '本机记录没有改动，已经同步的部分保留',
          next: '可以检查网络后重试',
        );
      });
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final signedIn = _account?.signedIn ?? false;
    return TabScaffold(
      header: const ZhixinHeader(nested: false, title: Text(tabMine)),
      child: PageWidth(
        child: ListView(
          padding: theme.space.pageInsets(),
          children: [
            if (!_loaded)
              const ListSkeleton(rows: 1, rowHeight: 168)
            else
              _AccountCard(
                account: _account,
                sync: _sync,
                quota: _quota,
                quotaLoading: _quotaLoading,
                syncing: _syncing || (_sync?.syncing ?? false),
                onSignIn: () => _push(openAccount),
                onManage: () => _push(openAccount),
                onSync: _syncNow,
              ),
            if (_notice != null)
              Padding(
                padding: EdgeInsets.only(top: theme.space.sm),
                child: _failed
                    ? InlineNotice(message: _notice!)
                    : Text(_notice!, style: theme.text.bodySmall),
              ),
            const SectionHeading(title: '数据'),
            if (signedIn) ...[
              _Entry(
                icon: FLucideIcons.cloud,
                title: '云端备份',
                subtitle: '上传、列出与下载整库快照',
                onPress: () => _push(openCloudBackup),
              ),
              SizedBox(height: theme.space.sm),
            ],
            _Entry(
              icon: FLucideIcons.history,
              title: '数据版本',
              subtitle: '提交历史、命名版本、导出与恢复',
              onPress: () => openDataVersion(context),
            ),
            const SectionHeading(title: '学习'),
            _Entry(
              icon: FLucideIcons.brain,
              title: '学习记忆',
              subtitle: '查看、修改和删除记忆',
              onPress: () => openMemory(context),
            ),
            SizedBox(height: theme.space.sm),
            _Entry(
              icon: FLucideIcons.sparkles,
              title: personaPageTitle,
              subtitle: personaEntrySubtitle,
              onPress: () => openPersona(context),
            ),
            SizedBox(height: theme.space.sm),
            _Entry(
              icon: FLucideIcons.package,
              title: pluginsPageTitle,
              subtitle: pluginsEntrySubtitle,
              onPress: () => openPlugins(context),
            ),
            const SectionHeading(title: '通用'),
            _Entry(
              icon: FLucideIcons.messageCircle,
              title: '反馈',
              subtitle: '提交问题与建议，不需要登录',
              onPress: () => _push(openFeedback),
            ),
            SizedBox(height: theme.space.sm),
            _Entry(
              icon: FLucideIcons.settings,
              title: '设置',
              subtitle: '模型、语义索引、截止时间与外观',
              // 设置页可能改了模型来源；回来之后账号卡不受影响，不必重读。
              onPress: () => openSettings(context),
            ),
            SizedBox(height: theme.space.sm),
            _Entry(
              icon: FLucideIcons.info,
              title: '关于',
              subtitle: '版本 $appVersion · 开源许可',
              onPress: () => openAbout(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行次级入口：左侧类型图标，右侧箭头，整行可点。
class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) => forui.FTile(
    prefix: LeadingIcon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    suffix: const Icon(FLucideIcons.chevronRight),
    onPress: onPress,
  );
}

/// 页首的账号卡：未登录时说明登录能多做什么并给登录按钮；登录之后显示邮箱、
/// 服务地址、同步状态与今日额度，给“立即同步”和“账号管理”。
class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.sync,
    required this.quota,
    required this.quotaLoading,
    required this.syncing,
    required this.onSignIn,
    required this.onManage,
    required this.onSync,
  });

  final AccountSnapshot? account;
  final SyncStatus? sync;
  final ServerQuota? quota;
  final bool quotaLoading;
  final bool syncing;
  final VoidCallback onSignIn;
  final VoidCallback onManage;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final account = this.account;
    final signedIn = account?.signedIn ?? false;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _Avatar(email: signedIn ? account!.email : null),
                SizedBox(width: theme.space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        signedIn ? account!.email : '未登录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text.titleMedium,
                      ),
                      SizedBox(height: theme.space.xs),
                      Text(
                        signedIn ? account!.serverLabel : '学习记录只保存在这台设备',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text.bodySmall.copyWith(
                          color: theme.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (signedIn) ...[SizedBox(width: theme.space.sm), _syncTag()],
              ],
            ),
            SizedBox(height: theme.space.md),
            if (!signedIn) ...[
              Text(
                '登录之后可以云端备份、在多台设备之间同步，并使用知新服务的模型额度。'
                '账号可选，不登录也能完整使用。',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.md),
              forui.FButton(
                onPress: onSignIn,
                prefix: const Icon(FLucideIcons.logIn),
                child: const Text('登录或注册'),
              ),
            ] else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Figure(label: '上次同步', value: _lastSynced()),
                  ),
                  SizedBox(width: theme.space.md),
                  Expanded(
                    child: _Figure(label: '今日模型额度', value: _quotaText()),
                  ),
                ],
              ),
              if (!account!.emailVerified) ...[
                SizedBox(height: theme.space.md),
                Text(
                  '邮箱还没有确认；在账号管理里确认之后，忘记密码时才能收到验证码。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.error,
                  ),
                ),
              ],
              if (sync?.lastError != null) ...[
                SizedBox(height: theme.space.md),
                InlineNotice(message: sync!.lastError!),
              ],
              SizedBox(height: theme.space.md),
              Row(
                children: [
                  Expanded(
                    child: forui.FButton(
                      onPress: syncing ? null : onSync,
                      prefix: const Icon(FLucideIcons.refreshCw),
                      child: Text(syncing ? '正在同步' : '立即同步'),
                    ),
                  ),
                  SizedBox(width: theme.space.sm),
                  Expanded(
                    child: forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      onPress: onManage,
                      child: const Text('账号管理'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _syncTag() {
    final sync = this.sync;
    if (syncing) return const StatusTag('同步中', tone: TagTone.accent);
    if (sync == null) return const StatusTag('状态未知', tone: TagTone.muted);
    if (sync.lastError != null) {
      return const StatusTag('同步失败', tone: TagTone.attention);
    }
    if (sync.needsBootstrap) {
      return const StatusTag('待首次同步', tone: TagTone.neutral);
    }
    if (sync.pendingCommits > 0) {
      return StatusTag('待同步 ${sync.pendingCommits} 条', tone: TagTone.neutral);
    }
    return const StatusTag('已同步', tone: TagTone.accent);
  }

  String _lastSynced() {
    final sync = this.sync;
    if (sync == null) return '暂时无法读取';
    final last = sync.lastSyncedAt;
    return last == null ? '还没有同步过' : shortTime(last);
  }

  String _quotaText() {
    if (quotaLoading) return '正在读取';
    final quota = this.quota;
    if (quota == null) return '暂时无法读取';
    return '${quota.usedTokens} / ${quota.dailyTokens} token';
  }
}

/// 账号卡里的一组小数据：上面一行说明，下面一行等宽数字。
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.text.labelMedium.copyWith(
            color: theme.colors.onSurfaceVariant,
          ),
        ),
        SizedBox(height: theme.space.xs),
        Text(value, style: theme.text.bodyMedium),
      ],
    );
  }
}

/// 头像：登录后用邮箱首字母放在主色浅底圆里，未登录用一个人形图标。
class _Avatar extends StatelessWidget {
  const _Avatar({this.email});

  final String? email;

  static const _size = 48.0;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final email = this.email;
    final initial = email == null || email.isEmpty
        ? null
        : email.characters.first.toUpperCase();
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: initial == null
            ? theme.colors.surfaceContainerHigh
            : theme.colors.primaryContainer,
      ),
      child: initial == null
          ? Icon(
              FLucideIcons.userRound,
              size: 24,
              color: theme.colors.onSurfaceVariant,
            )
          : Text(
              initial,
              style: theme.text.titleLarge.copyWith(
                color: theme.colors.onPrimaryContainer,
              ),
            ),
    );
  }
}
