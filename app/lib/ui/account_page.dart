import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'zhixin_dialog.dart';
import '../platform/app_paths.dart' show LocalSpace;

import '../app_scope.dart';
import '../application/account_actions.dart';
import '../application/account_service.dart';
import '../application/account_summary.dart';
import '../application/prefetch_results.dart';
import '../application/prefetch_service.dart';
import '../application/sync_flow.dart';
import '../application/sync_service.dart';
import '../domain/models/account_models.dart' show AccountIdentity;
import '../domain/models/server_models.dart' show ServerQuota;
import 'account_dialogs.dart';
import 'account_login_form.dart';
import 'navigation.dart';
import 'quota_purchase_panel.dart';
import 'quota_text.dart';
import 'cloud_sync_prompts.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'zhixin_header.dart';
import 'workspace_widgets.dart';

/// 账号与云同步：服务地址、登录注册、同步状态与云端数据操作。
///
/// 账号是可选项：不登录时应用完全在本机运行；登录之后才开启云端备份、按提交
/// 的增量同步与“知新服务”模型来源（ADR-0008）。
class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    this.initialReset = false,
    this.initialIdentifier = '',
  });

  /// 打开时直接显示找回密码的表单，不再显示登录卡与账号页的其他区块。
  ///
  /// 首次启动引导的“忘记密码”走这里：用户点一次就落在重设表单上，不必进了
  /// 账号页再找一次入口，也看不到设备名册、云端数据与退出登录这些与引导无关
  /// 的内容。
  final bool initialReset;

  /// 找回密码表单预填的邮箱；为空时留空。引导第二步已经填过邮箱，带过来省一次
  /// 输入。
  final String initialIdentifier;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _identifier = TextEditingController();
  final _verifyCode = TextEditingController();
  final _resetCode = TextEditingController();
  final _newPassword = TextEditingController();

  AccountSnapshot? _snapshot;
  SyncStatus? _sync;
  ServerQuota? _quota;
  List<LocalSpace> _spaces = const [];
  bool _loading = true;

  /// 登录卡与找回密码卡之间的切换；验证码发出之后在同一个位置继续输入。
  bool _showReset = false;

  /// 八类流程共用的操作状态：谁在跑、验证码属于哪一次流程、重发还要等多久。
  ///
  /// 状态与顺序都在应用层（[AccountActions]），页面只读 [AccountActionState] 决定
  /// 按钮可用与输入框是否出现（A30）。
  late AccountActions _actions;

  AccountActionState get _state => _actions.state;

  /// 页面顶部的一次性说明：失败用就地说明，成功用一行小字。
  String? _notice;
  bool _failed = false;

  /// 失败说明旁边可用的重试动作；成功说明与不需要重试的说明为空。
  VoidCallback? _noticeRetry;

  /// 本机设备标识：设备一节按它给这一行标“本机”（ADR-0048）。
  String? _localDeviceId;

  bool _started = false;

  @override
  void initState() {
    super.initState();
    _showReset = widget.initialReset;
    if (widget.initialIdentifier.isNotEmpty) {
      _identifier.text = widget.initialIdentifier;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final scope = AppScope.of(context);
    _actions = AccountActions(
      account: scope.accountServices.account,
      sync: scope.accountServices.sync,
      clearAllData: (password) => scope.clearAllData(password: password),
      deleteLocalSpace: scope.deleteLocalSpace,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    // 进入“我的”时已经在后台读过账号、同步状态与额度；先用这一份，
    // 这一次完整读取再把邮箱验证与额度刷新到最新。
    final prewarm = scope.prefetch.take<AccountPagePrewarm>(
      PrefetchKey.accountPage,
    );
    if (prewarm != null) {
      _snapshot = prewarm.snapshot;
      _sync = prewarm.sync;
      _quota = prewarm.quota;
      _loading = false;
    }
    _load();
  }

  @override
  void dispose() {
    _actions.dispose();
    _identifier.dispose();
    _verifyCode.dispose();
    _resetCode.dispose();
    _newPassword.dispose();
    super.dispose();
  }

  /// 账号摘要的唯一读取入口：账号页顺带核对一次登录方式并读今日额度。
  AccountSummaryReader get _reader {
    final services = AppScope.of(context).accountServices;
    return AccountSummaryReader(account: services.account, sync: services.sync);
  }

  /// 读账号摘要、本机空间并刷新页面。
  ///
  /// [keepNotice] 为真时读取失败只记诊断、不改页面提示：这类读取跟在一次操作
  /// 之后，刚给出的结论比后台读取失败更该留在页面上。
  Future<void> _load({bool keepNotice = false}) async {
    final scope = AppScope.of(context);
    try {
      final summary = await _reader.read(refresh: true, withQuota: true);
      final spaces = await scope.spaces?.list() ?? const <LocalSpace>[];
      if (!mounted) return;
      setState(() {
        _spaces = spaces;
        _snapshot = summary.snapshot;
        _sync = summary.sync;
        // 这一次没读到额度时保留上一次的数字：瞬时失败不该把已经读到的额度清空，
        // 否则页面看起来像额度没了。
        _quota = summary.quota ?? _quota;
        _localDeviceId = summary.localDeviceId;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      if (keepNotice) {
        setState(() => _loading = false);
        return;
      }
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

  void _report(String message, {bool failed = false, VoidCallback? retry}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _failed = failed;
      _noticeRetry = retry;
    });
  }

  /// 登录表单成功之后收尾：本机模式下登录会换空间，整棵子树重建，这一页随之
  /// 卸载，不再改它的状态；不换空间时报告成功并重读账号。
  Future<void> _signedIn(
    AccountSnapshot result, {
    required bool register,
  }) async {
    if (!mounted) return;
    if (AppScope.of(context).managesSpaces) return;
    _actions.clearCode();
    _showReset = false;
    final identifier = _identifier.text.trim();
    _report(
      '${register ? '注册并登录' : '登录'}成功：${result.displayLabel.isEmpty ? identifier : result.displayLabel}；'
      '云端备份与知新服务已经可用，需要时点“立即同步”把本机记录同步到这个账号',
    );
    await _load();
  }

  /// 需要确认的第一条登录方式；都确认过时为 null。
  AccountIdentity? get _unverifiedIdentity {
    for (final identity
        in _snapshot?.profile?.identities ?? const <AccountIdentity>[]) {
      if (!identity.verified) return identity;
    }
    return null;
  }

  /// 一次账号操作的收尾：操作状态、成功说明与统一的失败说明。
  ///
  /// 业务顺序与影响说明都在应用层（[AccountActions]），页面只在这里渲染结果；
  /// [retry] 是失败说明旁边可以再点一次的动作。
  Future<void> _run(
    AccountAction action,
    Future<AccountActionResult?> Function() body, {
    VoidCallback? retry,
  }) async {
    if (_state.busy) return;
    _actions.begin(action);
    try {
      final result = await body();
      if (!mounted || result == null) return;
      _report(
        result.message,
        failed: result.failed,
        retry: result.failed ? retry : null,
      );
      if (result.clearDigestMismatch) {
        setState(() => _sync = _sync?.withDigestMismatch(false));
      }
      if (result.reload) await _load(keepNotice: true);
    } catch (error, stack) {
      if (!mounted) return;
      final copy = accountActionCopy(action);
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: copy.action,
          kind: copy.kind,
          kept: copy.kept,
          next: copy.next,
        ),
        failed: true,
        retry: retry,
      );
      // 发送验证码被限流时要按服务端给的秒数继续禁用按钮。
      _actions.cooldownFrom(error);
    } finally {
      _actions.end();
    }
  }

  /// 验证码的发送按钮：冷却期间不可点，把还要等多久写在按钮上。
  Widget _sendCodeButton({
    required AccountAction action,
    required VoidCallback send,
  }) {
    final cooling = _state.cooling;
    return forui.FButton(
      mainAxisSize: MainAxisSize.min,
      onPress: (_state.busy || cooling) ? null : send,
      child: Text(
        cooling
            ? '${waitText(_state.resendWait)}后可重发'
            : (_state.codeSentFor(action) ? '重新发送' : '发送验证码'),
      ),
    );
  }

  Future<void> _sendVerification() async {
    if (_state.busy || _state.cooling) return;
    final identity = _unverifiedIdentity;
    if (identity == null) {
      _report('这个账号的登录方式都已经确认过');
      return;
    }
    await _run(
      AccountAction.sendIdentityCode,
      () => _actions.sendIdentityCode(
        identityId: identity.id,
        identifier: identity.identifier,
      ),
    );
  }

  Future<void> _confirmVerification() async {
    if (_state.busy) return;
    final identity = _unverifiedIdentity;
    if (identity == null) return;
    final code = _verifyCode.text.trim();
    await _run(AccountAction.confirmIdentity, () async {
      final result = await _actions.confirmIdentity(
        identityId: identity.id,
        kindLabel: identity.kindLabel,
        code: code,
      );
      if (!result.failed) _verifyCode.clear();
      return result;
    });
  }

  Future<void> _sendResetCode() => _run(
    AccountAction.sendResetCode,
    () => _actions.sendResetCode(identifier: _identifier.text.trim()),
  );

  Future<void> _resetPassword() => _run(AccountAction.resetPassword, () async {
    final result = await _actions.resetPassword(
      identifier: _identifier.text.trim(),
      code: _resetCode.text.trim(),
      password: _newPassword.text,
    );
    // 成功之后清掉两个输入框并回到登录卡；失败时留在原处，输入的内容不丢。
    if (!result.failed) {
      _newPassword.clear();
      _resetCode.clear();
      _showReset = false;
    }
    return result;
  });

  /// 立即同步：确认顺序与执行在 [SyncFlow] 里，页面只提供确认框与结论文案。
  Future<void> _syncNow() => _run(AccountAction.sync, () async {
    final flow = await AppScope.of(context).accountServices.sync.flow
        .run(confirm: (confirmation) => confirmSyncStep(context, confirmation));
    if (!mounted) return null;
    // 同步结束之后先就地更新“待修复”标记，再给结论：完整状态由随后的重读补齐，
    // 提示与状态卡不会在几帧里互相矛盾（ADR-0045）。
    if (flow.digestMismatch case final mismatch?) {
      setState(() => _sync = _sync?.withDigestMismatch(mismatch));
    }
    return AccountActionResult.ok(syncResultNotice(flow), reload: true);
  });

  /// 摘要不一致时的唯一修复入口：以本机为准重建云端。
  ///
  /// 清空账号的提交序列之后从 0 开始整份上传，不需要先分辨哪边多、哪边少，也不
  /// 会留下删不掉的行（过度设计审查 3.4）。确认框同时要求输入当前密码；失败时
  /// 云端与本机都不清空，已经上传的部分保留。
  Future<void> _rebuildCloudFromLocal() async {
    if (_state.busy) return;
    final password = await askDestructiveActionPassword(
      context,
      title: '以本机为准重建云端',
      message:
          '会清空这个账号在服务端的提交序列、快照、设备名册与命名版本，再把本机'
          '当前的记录整份上传为新的基线。云端备份与附件不受影响；其他设备下一次'
          '同步时会按首次同步重新上传它们本机的内容。操作不可撤销，需要输入当前密码。',
      confirmLabel: '重建云端',
    );
    if (password == null || !mounted) return;
    await _run(
      AccountAction.rebuildCloud,
      () => _actions.rebuildCloud(password: password),
    );
  }

  Future<void> _logout() async {
    if (_state.busy) return;
    final scope = AppScope.of(context);
    final managesSpaces = scope.managesSpaces;
    final deleteSpace = !managesSpaces
        ? false
        : await showZhixinDialog<bool>(
            context: context,
            builder: (context) => ZhixinDialogLayout(
              title: const Text('退出登录'),
              content: const Text('退出后打开本机空间。可以保留这个账号在此设备上的数据，或在退出时一起删除。'),
              actions: [
                cancelZhixinButton(context),
                forui.FButton(
                  variant: forui.FButtonVariant.destructive,
                  onPress: () => Navigator.of(context).pop(true),
                  child: const Text('退出并删除本机数据'),
                ),
                forui.FButton(
                  onPress: () => Navigator.of(context).pop(false),
                  child: const Text('退出并保留数据'),
                ),
              ],
            ),
          );
    if (deleteSpace == null || !mounted) return;
    await _run(
      AccountAction.logout,
      () => _actions.logout(
        deleteSpace: deleteSpace,
        managesSpaces: managesSpaces,
      ),
    );
  }

  Future<void> _clearAllData() async {
    if (_state.busy) return;
    final password = await askDestructiveActionPassword(
      context,
      title: '清除全部数据',
      message:
          '会清空当前本机空间的记录、附件、历史和设置，以及这个账号在服务端的数据。账号与登录状态保留。'
          '其他设备会在下次同步时重新上传它们的记录。要彻底清空，请先在其他设备退出登录或分别清除。',
      confirmLabel: '清除',
    );
    if (password == null || !mounted) return;
    final managesSpaces = AppScope.of(context).managesSpaces;
    await _run(
      AccountAction.clearAllData,
      () =>
          _actions.clearData(password: password, managesSpaces: managesSpaces),
      retry: _clearAllData,
    );
  }

  Future<void> _deleteAccount() async {
    if (_state.busy) return;
    // 即刻收按账号标识记余额，删号之后这份积分无人可用：确认删除之前先读一次
    // 余额；读不到按未知处理，不拿 0 去说明剩余积分，也不阻塞删除。
    final balancePoints = await _actions.remainingPointsBeforeDelete(
      contactVerified: _snapshot?.contactVerified ?? false,
    );
    if (!mounted) return;
    final password = await askDeleteAccountPassword(
      context,
      remainingPoints: balancePoints,
    );
    if (password == null || !mounted) return;
    final managesSpaces = AppScope.of(context).managesSpaces;
    await _run(
      AccountAction.deleteAccount,
      () => _actions.deleteAccount(
        password: password,
        managesSpaces: managesSpaces,
      ),
    );
  }

  Future<void> _setAutoSync(bool value) async {
    if (value) {
      final confirmed = await confirmEnableAutoSync(
        context,
        accountLabel: _snapshot?.displayLabel ?? '',
      );
      if (!confirmed || !mounted) return;
    }
    final account = AppScope.of(context).accountServices.account;
    try {
      // 快照由服务保存之后给出：页面不再自己拼一份，登录方式与额度入口都还在。
      final snapshot = await account.withAutoSync(value);
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
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

  /// 共享额度按积分显示：服务端只报计费 token，折算比例由 `tokens_per_point` 给出。
  /// 旧版服务端没有这一项时退回 token，避免把“不知道比例”显示成 0 积分。
  String _modelQuotaText() {
    final quota = _quota;
    if (quota == null) return '额度暂时无法读取';
    final ratio = quota.tokensPerPoint;
    if (ratio == null) {
      return '今日模型已用 ${quota.usedTokens} token · '
          '每日免费额度 ${quota.dailyTokens} token';
    }
    return '今日模型已用 ${quotaPoints(quota.usedTokens, ratio)} 积分 · '
        '每日免费额度 ${freeQuotaPoints(quota.dailyTokens, ratio)} 积分';
  }

  String _quotaDetailText() {
    final quota = _quota;
    if (quota == null) return '可以稍后重新进入这一页；备份与同步不受影响。';
    final ratio = quota.tokensPerPoint;
    final scale = ratio == null
        ? ''
        : '1 积分 = ${groupDigits(ratio)} 计费 token，用量向上取整；';
    return '$scale按 ${quota.day} 统计，重置时间以服务端时区为准。';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: ZhixinHeader(title: Text(_title), showBack: true),
      // 首读期间保留标题栏，内容用与卡片同高的骨架占位。
      child: _loading
          ? ListView(
              padding: theme.space.pageInsets(bottom: 96),
              children: const [ListSkeleton(rows: 3, rowHeight: 96)],
            )
          : _content(context),
    );
  }

  /// 从引导直接打开找回密码：只留这一张卡，不显示本机空间、账号状态与页尾说明。
  bool get _focusedReset => widget.initialReset && !_isSignedIn;

  bool get _isSignedIn => _snapshot?.signedIn ?? false;

  /// 从引导打开时标题跟着卡片走；正常从“我的”进来仍是账号与云同步。
  String get _title {
    if (!widget.initialReset) return '账号与云同步';
    return _showReset ? '找回密码' : '登录或注册';
  }

  Widget _content(BuildContext context) {
    final theme = context.zhixin;
    final snapshot = _snapshot;
    final signedIn = snapshot?.signedIn ?? false;
    final focused = _focusedReset;
    return ListView(
      padding: theme.space.pageInsets(bottom: 96),
      children: [
        if (_notice case final notice?)
          ResultNotice(message: notice, failed: _failed, onRetry: _noticeRetry),
        if (!focused && _spaces.isNotEmpty) ..._localSpaces(context),
        if (!signedIn) ..._loggedOut(context),
        if (signedIn) ..._loggedIn(context, snapshot!),
        if (!focused) ...[
          SizedBox(height: theme.space.md),
          Text(
            '学习记录默认保存在本机，登录之后才会使用服务端的备份、同步与模型代理；'
            '调用模型时只发送当次所需内容。令牌只保存在这台设备的 Keystore 里。',
            style: theme.text.bodySmall,
          ),
        ],
      ],
    );
  }

  List<Widget> _localSpaces(BuildContext context) {
    final scope = AppScope.of(context);
    return [
      const SectionHeading(title: '本机空间'),
      for (final space in _spaces)
        forui.FTile(
          title: Text(
            space.id == scope.spaceId ? '${space.label}（当前）' : space.label,
          ),
          subtitle: Text(formatBytes(space.bytes)),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _state.busy ? null : () => _deleteLocalSpace(space),
        ),
    ];
  }

  Future<void> _deleteLocalSpace(LocalSpace space) async {
    final scope = AppScope.of(context);
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除本机空间',
      content: Text('删除“${space.label}”在这台设备上的记录、历史、附件与设置。请先导出需要保留的数据包。'),
      confirmLabel: '删除本机空间',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      AccountAction.deleteLocalSpace,
      () =>
          _actions.deleteLocalSpaceById(spaceId: space.id, label: space.label),
    );
    // 删掉的是别的空间：当前空间的内容不变，不需要重读；当前空间在应用根里换掉。
    if (mounted && space.id != scope.spaceId) {
      unawaited(_load(keepNotice: true));
    }
  }

  List<Widget> _loggedOut(BuildContext context) {
    final theme = context.zhixin;
    // 本机模式（首次启动时选了“不同意”）下不提供登录入口：登录会把内容发到
    // 服务端，先要把用户须知与隐私政策同意回来。
    if (!AppScope.of(context).networkAllowed) return _localModeOnly(context);
    return [
      SectionHeading(
        title: _showReset ? '找回密码' : '登录或注册',
        first: true,
        subtitle: _showReset
            ? '向已经验证的邮箱发一封六位验证码，验证之后设置新密码；其他设备会退出登录。'
            : '登录之后可以上传整库备份、在多台设备之间同步，并使用知新服务的模型额度。',
      ),
      if (_snapshot?.serverLabel case final serverLabel?)
        Padding(
          padding: EdgeInsets.only(bottom: theme.space.sm),
          child: Text(serverLabel, style: theme.text.bodySmall),
        ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: _showReset ? _resetForm(context) : _loginForm(context),
        ),
      ),
    ];
  }

  /// 登录卡：与首次启动引导第二步共用同一个表单。
  Widget _loginForm(BuildContext context) => AccountLoginForm(
    identifier: _identifier,
    onSignedIn: _signedIn,
    onForgotPassword: () {
      setState(() => _showReset = true);
      _actions.clearCode();
      _actions.clearCooldown();
      _report('先点“发送验证码”，再填写邮件里的六位数字');
    },
  );

  /// 找回密码的表单；邮箱与登录卡共用同一个输入框控制器。
  Widget _resetForm(BuildContext context) {
    final theme = context.zhixin;
    final codeSent = _state.codeSentFor(AccountAction.sendResetCode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        forui.FTextField(
          control: .managed(controller: _identifier),
          keyboardType: TextInputType.emailAddress,
          label: const Text('邮箱'),
        ),
        SizedBox(height: theme.space.gap),
        if (codeSent) ...[
          forui.FTextField(
            control: .managed(controller: _resetCode),
            keyboardType: TextInputType.number,
            label: const Text('邮件里的六位验证码'),
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _newPassword),
            obscureText: true,
            label: const Text('新密码（至少 8 位）'),
          ),
          SizedBox(height: theme.space.md),
        ],
        Wrap(
          spacing: theme.space.sm,
          runSpacing: theme.space.sm,
          children: [
            _sendCodeButton(
              action: AccountAction.sendResetCode,
              send: _sendResetCode,
            ),
            if (codeSent)
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _state.busy ? null : _resetPassword,
                child: const Text('重设密码'),
              ),
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _state.busy
                  ? null
                  : () => setState(() {
                      _showReset = false;
                      _actions.clearCode();
                      _actions.clearCooldown();
                      _resetCode.clear();
                      _newPassword.clear();
                    }),
              child: const Text('返回登录'),
            ),
          ],
        ),
        if (codeSent) ...[
          SizedBox(height: theme.space.sm),
          Text(
            '没收到先看垃圾邮件；同一条登录方式一分钟内只能发一封，反复重发要等几小时。',
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// 本机模式下账号页的替代内容：说明现在停用了哪些联网功能，并给同意入口。
  List<Widget> _localModeOnly(BuildContext context) {
    final theme = context.zhixin;
    return [
      const SectionHeading(
        title: '登录或注册',
        first: true,
        subtitle: '首次启动时选择了仅在本机使用；同意用户须知与隐私政策之后才能登录。',
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '现在匿名使用统计、更新检查与登录都已停用，学习记录、材料、查找、'
                '导出与恢复照常可用。',
                style: theme.text.bodyMedium,
              ),
              SizedBox(height: theme.space.md),
              forui.FButton(
                mainAxisSize: MainAxisSize.max,
                onPress: () => openUserTerms(context),
                child: const Text('查看并同意用户须知'),
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
    // 确认登录方式的卡片用这一份：验证码只对“确认登录方式”那一次流程生效。
    final codeSent = _state.codeSentFor(AccountAction.sendIdentityCode);
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
              // 登录方式列表：现在只有一条邮箱，以后加手机号或微信时这里自然多
              // 出一行，页面结构不用改。
              for (final identity
                  in snapshot.profile?.identities ?? const <AccountIdentity>[])
                Padding(
                  padding: EdgeInsets.only(bottom: theme.space.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${identity.kindLabel}：${identity.identifier}',
                          style: theme.text.bodyMedium,
                        ),
                      ),
                      StatusTag(
                        identity.verified ? '已确认' : '未确认',
                        tone: identity.verified
                            ? TagTone.accent
                            : TagTone.attention,
                      ),
                    ],
                  ),
                ),
              if ((snapshot.profile?.identities ?? const []).isEmpty)
                Text('登录方式暂时无法读取', style: theme.text.bodyMedium),
              SizedBox(height: theme.space.xs),
              Text(
                snapshot.serverLabel,
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.xs),
              Text(
                snapshot.contactVerified
                    ? '至少一种登录方式已确认，忘记密码时可以收到验证码。'
                    : '还没有确认任何登录方式；先确认一种，忘记密码时才能收到重设验证码。',
                style: theme.text.bodySmall.copyWith(
                  color: snapshot.contactVerified
                      ? theme.colors.onSurfaceVariant
                      : theme.colors.error,
                ),
              ),
              SizedBox(height: theme.space.sm),
              forui.FSwitch(
                label: const Text('自动同步'),
                description: const Text('写入之后在后台推送；关闭后只在上面的“立即同步”里执行。'),
                value: snapshot.autoSync,
                onChange: _state.busy ? null : _setAutoSync,
              ),
            ],
          ),
        ),
      ),
      if (_unverifiedIdentity != null) ...[
        SectionHeading(
          title: '确认登录方式',
          subtitle: '验证码发到这条登录方式，十分钟内有效；确认之后找回密码才能用。',
        ),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_unverifiedIdentity!.kindLabel} ${_unverifiedIdentity!.identifier}',
                  style: theme.text.bodyMedium,
                ),
                if (codeSent) SizedBox(height: theme.space.md),
                if (codeSent)
                  forui.FTextField(
                    control: .managed(controller: _verifyCode),
                    keyboardType: TextInputType.number,
                    label: const Text('邮件里的六位验证码'),
                  ),
                if (codeSent) SizedBox(height: theme.space.md),
                Wrap(
                  spacing: theme.space.sm,
                  runSpacing: theme.space.sm,
                  children: [
                    _sendCodeButton(
                      action: AccountAction.sendIdentityCode,
                      send: _sendVerification,
                    ),
                    if (codeSent)
                      forui.FButton(
                        variant: forui.FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _state.busy ? null : _confirmVerification,
                        child: const Text('确认'),
                      ),
                  ],
                ),
                if (codeSent) ...[
                  SizedBox(height: theme.space.sm),
                  Text(
                    '没收到先看垃圾邮件；同一条登录方式一分钟内只能发一封，反复重发要等几小时。',
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
      SectionHeading(
        title: '同步',
        subtitle: '服务端保存同一条提交序列的另一份；两台设备同时修改同一字段时后到达的覆盖先到达的。',
        action: StatusTag(
          sync?.syncing == true
              ? '同步中'
              : sync?.digestMismatch == true
              ? '待修复'
              : (sync?.lastError == null ? '空闲' : '上次失败'),
          tone: sync?.lastError == null && sync?.digestMismatch != true
              ? TagTone.muted
              : TagTone.attention,
        ),
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_syncSummary(sync), style: theme.text.bodyMedium),
              if (sync?.digestMismatch == true) ...[
                SizedBox(height: theme.space.sm),
                Text(
                  '本机与云端不一致',
                  style: theme.text.bodyMedium.copyWith(
                    color: theme.colors.error,
                  ),
                ),
                if (sync!.differentTables.isNotEmpty)
                  Text('差异表 ${sync.differentTables.map(tableLabel).join('、')}'),
                SizedBox(height: theme.space.xs),
                Text(
                  '上次同步比较整库摘要时发现两边内容不同。修复只有一个入口：'
                  '以本机为准重建云端，会清空这个账号在服务端的提交序列，再把本机'
                  '当前的记录整份上传为新的基线；云端备份与附件保留，其他设备下次'
                  '同步时会重新上传它们本机的内容。修复只改记录，不影响登录状态。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: theme.space.sm),
                forui.FButton(
                  variant: forui.FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _state.busy || sync.syncing
                      ? null
                      : _rebuildCloudFromLocal,
                  child: const Text('以本机为准重建云端'),
                ),
              ],
              if (sync?.restoreNeedsConfirmation == true) ...[
                SizedBox(height: theme.space.xs),
                Text(
                  '恢复之后需要重新对齐：下一步同步会把云端改成恢复后的内容，'
                  '点“立即同步”之后确认。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ],
              if (sync?.baselineNeedsConfirmation == true) ...[
                SizedBox(height: theme.space.xs),
                Text(
                  '首次同步需要确认：会把本机现有的 ${sync!.localHead} 条提交上传到'
                  '这个账号；点“立即同步”之后确认。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ],
              if (sync?.lastError != null) ...[
                SizedBox(height: theme.space.sm),
                InlineNotice(
                  message: sync!.lastError!,
                  onRetry: _state.busy ? null : _syncNow,
                ),
              ],
              SizedBox(height: theme.space.md),
              Wrap(
                spacing: theme.space.sm,
                runSpacing: theme.space.sm,
                children: [
                  forui.FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: _state.busy || sync?.syncing == true
                        ? null
                        : _syncNow,
                    prefix: const Icon(FLucideIcons.refreshCw),
                    child: const Text('立即同步'),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _state.busy
                        ? null
                        : () => openCloudBackup(context),
                    child: const Text('云端备份'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      ..._devicesSection(context),
      SectionHeading(title: '模型额度', subtitle: '聊天和嵌入共用每日免费额度，用完后扣购买积分。'),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_modelQuotaText(), style: theme.text.bodyMedium),
              if (_quota case final quota?)
                Text(
                  modelUsageText(
                    chatTokens: quota.chatUsedTokens,
                    embeddingTokens: quota.embeddingUsedTokens,
                    tokensPerPoint: quota.tokensPerPoint,
                  ),
                  style: theme.text.bodyMedium,
                ),
              if (pointsQuotaText(
                    chargedPoints: _quota?.chargedPoints,
                    remainingPoints: _quota?.remainingPoints,
                  )
                  case final pointsText when pointsText.isNotEmpty)
                Text(pointsText, style: theme.text.bodyMedium),
              SizedBox(height: theme.space.xs),
              Text(
                _quotaDetailText(),
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      if (_snapshot?.contactVerified == true)
        QuotaPurchasePanel(
          key: ValueKey((_snapshot!.serverBaseUrl, _snapshot!.session!.userId)),
          account: AppScope.of(context).accountServices.account,
          enabled: !_state.busy,
          dailyTokens: _quota?.dailyTokens,
          onPaid: _load,
        ),
      SectionHeading(title: '账号与数据管理'),
      forui.FTile(
        variant: forui.FItemVariant.destructive,
        prefix: const LeadingIcon(FLucideIcons.cloudOff, tone: TagTone.muted),
        title: const Text('清除全部数据'),
        subtitle: const Text('清空当前本机空间和云端数据，保留账号与登录状态。'),
        suffix: const Icon(FLucideIcons.trash2),
        onPress: _state.busy ? null : _clearAllData,
      ),
      SizedBox(height: theme.space.sm),
      forui.FTile(
        variant: forui.FItemVariant.destructive,
        prefix: const LeadingIcon(FLucideIcons.userX, tone: TagTone.muted),
        title: const Text('删除账号'),
        subtitle: const Text('删除账号、云端数据及这个账号的本机空间。'),
        suffix: const Icon(FLucideIcons.trash2),
        onPress: _state.busy ? null : _deleteAccount,
      ),
      SizedBox(height: theme.space.md),
      forui.FTile(
        prefix: const LeadingIcon(FLucideIcons.logOut),
        title: const Text('退出登录'),
        subtitle: const Text('退出这台设备；云端数据保留，下次登录可以继续同步。'),
        suffix: const Icon(FLucideIcons.chevronRight),
        onPress: _state.busy ? null : _logout,
      ),
    ];
  }

  /// 设备一节：名册里的每台设备一行，本机标“本机”，行尾提供改名（ADR-0048）。
  ///
  /// 名册只记录发过同步请求的设备；缓存为空时说明原因，不显示一张只有空白的卡片。
  List<Widget> _devicesSection(BuildContext context) {
    final theme = context.zhixin;
    final sync = AppScope.of(context).accountServices.sync;
    return [
      const SectionHeading(
        title: '设备',
        subtitle: '这个账号发过同步请求的设备；别名只影响显示，不影响同步与已经推送的记录。',
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sync.devices.isEmpty)
                Text(
                  '还没有设备同步过这个账号；这台设备同步一次之后会出现在这里。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                )
              else
                for (final device in sync.devices)
                  _deviceRow(theme, sync, device),
            ],
          ),
        ),
      ),
    ];
  }

  /// 一台设备一行：别名或“未命名设备”、标识前 8 位、最近出现时间与本机标记。
  Widget _deviceRow(
    ZhixinTheme theme,
    SyncService sync,
    SyncRosterDevice device,
  ) {
    final name = device.trimmedAlias.isEmpty ? '未命名设备' : device.trimmedAlias;
    final local = _localDeviceId != null && device.deviceId == _localDeviceId;
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text.bodyMedium,
                      ),
                    ),
                    if (local) ...[
                      SizedBox(width: theme.space.xs),
                      const StatusTag('本机', tone: TagTone.accent),
                    ],
                  ],
                ),
                Text(
                  '${maskedDeviceId(device.deviceId)} · ${_deviceSeen(device.lastSeen)}',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: theme.space.sm),
          forui.FButton(
            variant: forui.FButtonVariant.outline,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: _state.busy ? null : () => _renameDevice(device),
            child: const Text('改名'),
          ),
        ],
      ),
    );
  }

  /// 改一台设备的别名：输入 0–64 个字符，确定之后保存并刷新列表。
  ///
  /// 取消不改动；失败按统一的失败说明提示，同步缓存保持原样（ADR-0048）。
  Future<void> _renameDevice(SyncRosterDevice device) async {
    if (_state.busy) return;
    final alias = await promptDeviceAlias(
      context,
      currentAlias: device.trimmedAlias,
    );
    if (alias == null || !mounted) return;
    // 改名接口已经替换缓存里这一行，结论给出后的重绘就带出新别名。
    await _run(
      AccountAction.renameDevice,
      () => _actions.renameDevice(deviceId: device.deviceId, alias: alias),
    );
  }

  /// 最近出现时间：读不出时写“时间未知”，与提交列表同一套短时间格式。
  static String _deviceSeen(DateTime? lastSeen) =>
      lastSeen == null ? '最近出现时间未知' : '最近出现 ${shortTime(lastSeen)}';

  String _syncSummary(SyncStatus? sync) {
    if (sync == null) return '同步状态暂时无法读取。';
    if (!sync.signedIn) return '还没有登录。';
    final last = sync.lastSyncedAt;
    final lastText = last == null ? '还没有同步过' : '上次同步 ${shortTime(last)}';
    final serverHead = sync.serverHead;
    final pending = sync.restoreNeedsConfirmation
        ? '恢复后待对齐'
        : (sync.needsBootstrap ? '首次同步' : '${sync.pendingCommits} 条提交');
    return '$lastText · 本机 HEAD ${sync.localHead}'
        '${serverHead == null ? '' : ' · 服务端位置 $serverHead'}'
        ' · 待同步 $pending';
  }
}
