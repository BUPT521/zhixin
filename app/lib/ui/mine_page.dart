import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/account_summary.dart';
import '../application/prefetch_results.dart';
import '../application/prefetch_service.dart';
import '../application/sync_flow.dart';
import '../application/sync_service.dart';
import '../domain/models/server_models.dart' show ServerQuota;
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
  ///
  /// 读法走账号摘要的唯一入口：先读本机就能拿到的账号与同步状态，账号卡立刻
  /// 出现，额度这一步要走网络，回来再补上。
  ///
  /// [keepNotice] 为真时读取失败只记诊断、不改账号卡下方的说明：这类读取跟在
  /// 一次操作之后，刚给出的结论比后台读取失败更该留在页面上。
  Future<void> _load({bool keepNotice = false}) async {
    final scope = AppScope.of(context);
    final services = scope.accountServices;
    final reader = AccountSummaryReader(
      account: services.account,
      sync: services.sync,
    );
    final sequence = ++_loadSequence;
    try {
      final summary = await reader.read();
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _account = summary.snapshot;
        _sync = summary.sync;
        _loaded = true;
        if (!summary.signedIn) _quota = null;
        _quotaLoading = summary.signedIn;
      });
      if (!summary.signedIn) {
        // 账号页读的是同一份数据，留给它之后打开直接用。
        scope.prefetch.put<AccountPagePrewarm>(
          PrefetchKey.accountPage,
          summary,
        );
        return;
      }
      final remaining = await reader.readQuota();
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _quota = remaining;
        _quotaLoading = false;
      });
      scope.prefetch.put<AccountPagePrewarm>(
        PrefetchKey.accountPage,
        summary.copyWith(quota: remaining),
      );
    } catch (error, stack) {
      if (!mounted || sequence != _loadSequence) return;
      if (keepNotice) {
        setState(() => _loaded = true);
        return;
      }
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

  /// 立即同步：确认顺序与执行在 [SyncFlow] 里，页面只提供确认框与结论文案。
  Future<void> _syncNow() async {
    if (_syncing) return;
    final services = AppScope.of(context).accountServices;
    setState(() {
      _syncing = true;
      _notice = null;
    });
    try {
      final flow = await services.sync.flow.run(
        confirm: (confirmation) => confirmSyncStep(context, confirmation),
      );
      if (!mounted) return;
      setState(() {
        _failed = false;
        _notice = syncResultNotice(flow);
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
    if (mounted) await _load(keepNotice: true);
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
            if (_notice case final notice?)
              Padding(
                padding: EdgeInsets.only(top: theme.space.sm),
                child: ResultNotice(message: notice, failed: _failed),
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
              subtitle: '版本 $appVersionLabel · 开源许可',
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
    // 账号显示的一行就是第一种登录方式的值；资料还没读到时用一句说明占位。
    final label = account?.displayLabel ?? '';
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _Avatar(label: signedIn ? label : null),
                SizedBox(width: theme.space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        signedIn ? (label.isEmpty ? '已登录的账号' : label) : '未登录',
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
              if (!account!.contactVerified) ...[
                SizedBox(height: theme.space.md),
                Text(
                  '还没有确认任何登录方式；在账号管理里确认之后，忘记密码时才能收到验证码。',
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
    if (sync.digestMismatch) {
      // 两台设备的摘要对不上：账号页给两个修复入口，这里只提示需要处理，
      // 不在“我的”页放修复按钮，避免同一件事有两个入口（ADR-0045）。
      return const StatusTag('待修复', tone: TagTone.attention);
    }
    if (sync.needsBootstrap) {
      return const StatusTag('待首次同步', tone: TagTone.neutral);
    }
    if (sync.restoreNeedsConfirmation) {
      return const StatusTag('恢复后待对齐', tone: TagTone.attention);
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
    final ratio = quota.tokensPerPoint;
    if (ratio == null) {
      return '${quota.usedTokens} / ${quota.dailyTokens} token';
    }
    return '${quotaPoints(quota.usedTokens, ratio)} / '
        '${freeQuotaPoints(quota.dailyTokens, ratio)} 积分';
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

/// 头像：登录后用账号显示名的首字放在主色浅底圆里，未登录用一个人形图标。
/// 以后加头像图片时，这里多一个图片来源，[label] 仍作为后缀与备用。
class _Avatar extends StatelessWidget {
  const _Avatar({this.label});

  final String? label;

  static const _size = 48.0;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final label = this.label;
    final initial = label == null || label.isEmpty
        ? null
        : label.characters.first.toUpperCase();
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
