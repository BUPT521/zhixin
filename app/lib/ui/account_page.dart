import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'zhixin_dialog.dart';
import '../platform/app_paths.dart' show LocalSpace;

import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/prefetch_service.dart';
import '../application/sync_service.dart';
import '../data/cloud/account_store.dart' show AccountIdentity;
import '../data/cloud/server_client.dart' show ServerProblem, ServerQuota;
import 'account_dialogs.dart';
import 'quota_purchase_panel.dart';
import 'quota_text.dart';
import 'cloud_sync_prompts.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'navigation.dart';
import 'zhixin_header.dart';
import 'workspace_widgets.dart';

/// 一级界面切进来之后预读的账号页首屏；字段与预读任务返回的记录一致。
typedef _AccountPrewarm = ({
  AccountSnapshot snapshot,
  SyncStatus sync,
  ServerQuota? quota,
});

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
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _verifyCode = TextEditingController();
  final _resetCode = TextEditingController();
  final _newPassword = TextEditingController();

  AccountSnapshot? _snapshot;
  SyncStatus? _sync;
  ServerQuota? _quota;
  List<LocalSpace> _spaces = const [];
  bool _loading = true;
  bool _busy = false;

  /// 登录卡与找回密码卡之间的切换；验证码发出之后在同一个位置继续输入。
  bool _showReset = false;
  bool _codeSent = false;

  /// 重发倒计时：服务端对同一条登录方式一分钟内只发一封（`ZHIXIN_CODE_COOLDOWN`
  /// 默认 60 秒），界面按同一个间隔禁用按钮，用户不必先点一次拿到 429 才知道要等。
  int _resendWait = 0;
  Timer? _resendTicker;

  /// 页面顶部的一次性说明：失败用就地说明，成功用一行小字。
  String? _notice;
  bool _failed = false;

  /// 失败说明旁边可用的重试动作；成功说明与不需要重试的说明为空。
  VoidCallback? _noticeRetry;

  /// 本机设备标识：设备一节按它给这一行标“本机”（ADR-0048）。
  String? _localDeviceId;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 进入“我的”时已经在后台读过账号、同步状态与额度；先用这一份，
    // 这一次完整读取再把邮箱验证与额度刷新到最新。
    final prewarm = AppScope.of(context).prefetch
        .take<_AccountPrewarm>(PrefetchKey.accountPage);
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
    _resendTicker?.cancel();
    _identifier.dispose();
    _password.dispose();
    _verifyCode.dispose();
    _resetCode.dispose();
    _newPassword.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      // 顺带核对一次邮箱验证状态；没有登录或服务端不可达时沿用本机记录。
      final snapshot = await scope.accountServices.account.refreshAccount();
      final sync = await scope.accountServices.sync.status();
      ServerQuota? quota;
      String? localDeviceId;
      if (snapshot.signedIn) {
        try {
          quota = await scope.accountServices.account.quota();
        } catch (_) {
          // 额度只用于显示；读不到时这一块给一句说明，不影响同步与备份。
        }
        try {
          localDeviceId = await scope.accountServices.account.deviceId();
        } catch (_) {
          // 读不到设备标识时设备一节不标“本机”，其他内容照常显示。
        }
        // 设备一节直接读同步服务缓存的名册；读取失败只记诊断，不阻塞本页。
        await scope.accountServices.sync.refreshDevices();
      }
      final spaces = await scope.spaces?.list() ?? const <LocalSpace>[];
      if (!mounted) return;
      setState(() {
        _spaces = spaces;
        _snapshot = snapshot;
        _sync = sync;
        // 这一次没读到额度时保留上一次的数字：瞬时失败不该把已经读到的额度清空，
        // 否则页面看起来像额度没了。
        _quota = quota ?? _quota;
        _localDeviceId = localDeviceId;
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

  void _report(String message, {bool failed = false, VoidCallback? retry}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _failed = failed;
      _noticeRetry = retry;
    });
  }

  Future<void> _submit({required bool register}) async {
    if (_busy) return;
    final identifier = _identifier.text.trim();
    final password = _password.text;
    if (identifier.isEmpty || password.isEmpty) {
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
      final account = scope.accountServices.account;
      final result = register
          ? await account.register(identifier: identifier, password: password)
          : await account.login(identifier: identifier, password: password);
      if (!mounted || scope.managesSpaces) return;
      _password.clear();
      // 登录之后是“确认登录方式”的流程，找回密码那一套的验证码状态要清掉。
      _codeSent = false;
      _showReset = false;
      await scope.accountServices.sync.schedule(
        delay: const Duration(seconds: 1),
      );
      _report(
        '${register ? '注册并登录' : '登录'}成功：${result.displayLabel.isEmpty ? identifier : result.displayLabel}；'
        '云端备份与知新服务已经可用，需要时点“立即同步”把本机记录同步到这个账号',
      );
      await _load();
    } on FormatException catch (error) {
      if (!mounted) return;
      _report(error.message, failed: true);
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

  /// 需要确认的第一条登录方式；都确认过时为 null。
  AccountIdentity? get _unverifiedIdentity {
    for (final identity
        in _snapshot?.profile?.identities ?? const <AccountIdentity>[]) {
      if (!identity.verified) return identity;
    }
    return null;
  }

  /// 服务端默认的冷却时间；成功响应不带 `Retry-After`，先按这个值禁用按钮。
  static const _resendCooldownSeconds = 60;

  /// 按服务端给出的等待秒数开始倒计时，0 表示现在就可以再发。
  void _startResendCooldown(int seconds) {
    _resendTicker?.cancel();
    _resendTicker = null;
    if (seconds <= 0) {
      if (_resendWait != 0) setState(() => _resendWait = 0);
      return;
    }
    setState(() => _resendWait = seconds);
    // 收信预算用完时要等几个小时，按秒刷新只会白白唤醒页面，长等待按半分钟走。
    final step = seconds > 120 ? 30 : 1;
    _resendTicker = Timer.periodic(Duration(seconds: step), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = _resendWait - step;
      if (next <= 0) {
        timer.cancel();
        _resendTicker = null;
        setState(() => _resendWait = 0);
      } else {
        setState(() => _resendWait = next);
      }
    });
  }

  /// 服务端说还要等多久就按这个秒数继续禁用按钮；其余失败不动倒计时。
  void _startResendCooldownFrom(Object error) {
    if (error is! ServerProblem) return;
    final seconds = error.retryAfterSeconds;
    if (seconds == null || seconds <= 0) return;
    _startResendCooldown(seconds);
  }

  /// 登录与找回密码之间切换时清掉，另一个入口的冷却不该挡住这一次发送。
  void _clearResendCooldown() {
    _resendTicker?.cancel();
    _resendTicker = null;
    _resendWait = 0;
  }

  /// 验证码的发送按钮：冷却期间不可点，把还要等多久写在按钮上。
  Widget _sendCodeButton({required VoidCallback send}) {
    final cooling = _resendWait > 0;
    return forui.FButton(
      mainAxisSize: MainAxisSize.min,
      onPress: (_busy || cooling) ? null : send,
      child: Text(
        cooling
            ? '${waitText(_resendWait)}后可重发'
            : (_codeSent ? '重新发送' : '发送验证码'),
      ),
    );
  }

  Future<void> _sendVerification() async {
    if (_busy || _resendWait > 0) return;
    final identity = _unverifiedIdentity;
    if (identity == null) {
      _report('这个账号的登录方式都已经确认过');
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.account
          .requestIdentityVerification(identity.id);
      _codeSent = true;
      _startResendCooldown(_resendCooldownSeconds);
      _report('验证码已经发到 ${identity.identifier}，十分钟内有效');
    } catch (error, stack) {
      if (!mounted) return;
      _startResendCooldownFrom(error);
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '发送验证码',
          kind: 'account_identifier_code',
          kept: '登录状态没有改动',
          next: '可以检查邮箱与服务地址后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmVerification() async {
    if (_busy) return;
    final identity = _unverifiedIdentity;
    final code = _verifyCode.text.trim();
    if (identity == null) return;
    if (code.length != 6) {
      _report('填写邮件里的六位验证码', failed: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.account
          .confirmIdentityVerification(identity.id, code);
      _verifyCode.clear();
      _codeSent = false;
      _report('${identity.kindLabel}已经确认；忘记密码时可以收到重设验证码');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '确认登录方式',
          kind: 'account_identifier_confirm',
          kept: '登录状态没有改动',
          next: '可以重新获取验证码再试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendResetCode() async {
    if (_busy || _resendWait > 0) return;
    final identifier = _identifier.text.trim();
    if (identifier.isEmpty) {
      _report('先填写注册用的邮箱', failed: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.account
          .requestPasswordReset(identifier);
      _startResendCooldown(_resendCooldownSeconds);
      _report('如果这个邮箱注册并验证过，验证码已经发出；十分钟内有效');
    } catch (error, stack) {
      if (!mounted) return;
      _startResendCooldownFrom(error);
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '发送重设验证码',
          kind: 'account_reset_code',
          kept: '登录状态与密码没有改动',
          next: '可以检查邮箱与服务地址后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_busy) return;
    final identifier = _identifier.text.trim();
    final code = _resetCode.text.trim();
    final password = _newPassword.text;
    if (identifier.isEmpty) {
      _report('先填写注册用的邮箱', failed: true);
      return;
    }
    if (code.length != 6) {
      _report('填写邮件里的六位验证码', failed: true);
      return;
    }
    if (password.length < 8) {
      _report('新密码至少 8 位', failed: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.account.resetPassword(
        identifier: identifier,
        code: code,
        newPassword: password,
      );
      _password.clear();
      _newPassword.clear();
      _resetCode.clear();
      _codeSent = false;
      _showReset = false;
      _report('密码已经重设，请用新密码登录；其他设备需要重新登录');
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '重设密码',
          kind: 'account_reset',
          kept: '密码没有改动',
          next: '可以重新获取验证码再试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    final scope = AppScope.of(context);
    var confirmBaseline = false;
    try {
      final status = await scope.accountServices.sync.status();
      if (status.restoreNeedsConfirmation) {
        if (!mounted) return;
        final confirmed = await confirmRestoreAlignment(context);
        if (!confirmed) {
          if (!mounted) return;
          _report('已取消同步；恢复后的内容仍在本机，需要时可以再点“立即同步”');
          await _load();
          return;
        }
        confirmBaseline = true;
      } else if (status.baselineNeedsConfirmation) {
        if (!mounted) return;
        final confirmed = await confirmBaselineUpload(
          context,
          localCommits: status.localHead,
        );
        if (!confirmed) {
          // 取消就不上传，并把自动同步停下来；恢复要在开关上再确认一次。
          await scope.accountServices.account.setAutoSync(false);
          if (!mounted) return;
          _report('已取消首次同步，没有上传本机记录；自动同步已暂停');
          await _load();
          return;
        }
        confirmBaseline = true;
      }
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '读取同步状态',
          kind: 'account_sync_status',
          kept: '本机记录没有改动',
          next: '可以稍后再试',
        ),
        failed: true,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      // 云端历史被压缩时同步会抛出 SyncSnapshotProblem（code 为
      // confirmationRequired）：先说明再确认，确认之后带 confirmReclone 再跑一轮，
      // 本机数据不在未确认时被替换（3.7）。
      var confirmReclone = false;
      while (true) {
        try {
          final result = await scope.accountServices.sync.syncNow(
            confirmBaseline: confirmBaseline,
            confirmReclone: confirmReclone,
          );
          // 同步结束之后先就地更新“待修复”标记，再给结论：完整状态随后由后台
          // 重读补齐，提示与状态卡不会在几帧里互相矛盾（ADR-0045）。
          final mismatch = await scope.accountServices.sync.digestMismatch();
          if (!mounted) return;
          setState(() => _sync = _sync?.withDigestMismatch(mismatch));
          _report(
            result.changed
                ? '同步完成：拉取 ${result.pulledCommits} 条、推送 ${result.pushedCommits} 条提交，'
                      '上传 ${result.uploadedAssets}、下载 ${result.downloadedAssets} 个附件'
                : (_sync?.digestMismatch ?? false)
                ? '同步完成；本机与云端的内容仍不一致，按上面的说明选择修复方式'
                : '同步完成，本机与云端已经一致',
          );
          unawaited(_load());
          return;
        } on SyncSnapshotProblem catch (problem) {
          if (problem.code != SyncSnapshotCode.confirmationRequired) rethrow;
          if (!mounted) return;
          final confirmed = await confirmSnapshotRebuild(
            context,
            localCommits: problem.localCommits,
          );
          if (!confirmed) {
            if (!mounted) return;
            _report('已取消同步；本机数据保持不变，需要时可以再点“立即同步”');
            await _load();
            return;
          }
          confirmReclone = true;
        }
      }
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

  /// 摘要不一致时的唯一修复入口：以本机为准重建云端。
  ///
  /// 清空账号的提交序列之后从 0 开始整份上传，不需要先分辨哪边多、哪边少，也不
  /// 会留下删不掉的行（过度设计审查 3.4）。确认框同时要求输入当前密码；失败时
  /// 云端与本机都不清空，已经上传的部分保留。
  Future<void> _rebuildCloudFromLocal() async {
    if (_busy) return;
    final password = await askDestructiveActionPassword(
      context,
      title: '以本机为准重建云端',
      message:
          '会清空这个账号在服务端的提交序列、快照、设备名册与命名版本，再把本机'
          '当前的记录整份上传为新的基线。云端备份与附件不受影响；其他设备下一次'
          '同步时会按首次同步重新上传它们本机的内容。操作不可撤销，需要输入当前密码。',
      confirmLabel: '重建云端',
    );
    if (password == null || !mounted || _busy) return;
    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      final result = await scope.accountServices.sync.rebuildCloudFromLocal(
        password: password,
      );
      if (!mounted) return;
      // 先摘掉状态卡上的“待修复”，再给结论，其余状态由后台重读补齐，提示与
      // 状态卡因此不会互相矛盾（ADR-0045）。
      setState(() => _sync = _sync?.withDigestMismatch(false));
      _report(
        result.pushedCommits > 0
            ? '已按本机重建云端：上传 ${result.pushedCommits} 条提交、'
                  '${result.uploadedAssets} 个附件；其他设备下次同步会重新上传'
                  '它们本机的内容'
            : '云端已经按本机当前内容重建，没有需要上传的改动',
      );
      unawaited(_load());
    } catch (error, stack) {
      if (!mounted) return;
      if (error is ServerProblem && error.isConflict) {
        _report('该账号还有云端操作在进行，请稍后重试');
      } else if (error is ServerProblem &&
          error.code == 'invalid_credentials') {
        _report('密码不正确；云端与本机数据都没有改动', failed: true);
      } else {
        _report(
          describeFailure(
            context,
            error,
            stack,
            action: '重建云端',
            kind: 'account_sync_rebuild',
            kept: '本机记录没有删除；云端可能已经清空，再试一次会按首次同步重新对齐',
            next: '可以检查网络后再试',
          ),
          failed: true,
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final scope = AppScope.of(context);
      final deleteSpace = !scope.managesSpaces
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
      await scope.accountServices.account.logout(deleteSpace: deleteSpace);
      if (!mounted || scope.managesSpaces) return;
      // 退出之后同步位置不再继续推进，不能一直挡住“清理历史”；位置与账号
      // 归属保留，重新登录同一账号时仍从原位置继续增量同步（同步方案 3.3）。
      await scope.accountServices.sync.clearState();
      _report('已退出登录；本机记录仍在，云端数据保留，重新登录同一账号可以接着同步');
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

  Future<void> _clearAllData() async {
    if (_busy) return;
    final password = await askDestructiveActionPassword(
      context,
      title: '清除全部数据',
      message:
          '会清空当前本机空间的记录、附件、历史和设置，以及这个账号在服务端的数据。账号与登录状态保留。'
          '其他设备会在下次同步时重新上传它们的记录。要彻底清空，请先在其他设备退出登录或分别清除。',
      confirmLabel: '清除',
    );
    if (password == null || !mounted || _busy) return;
    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      await scope.clearAllData(password: password);
      if (!mounted || scope.managesSpaces) return;
      _report('本机与云端数据已清除，登录状态保留');
      await _load();
    } on ServerProblem catch (error, stack) {
      if (!mounted) return;
      if (error.isConflict) {
        _report('该账号还有云端操作在进行，请稍后重试');
      } else if (error.code == 'invalid_credentials') {
        _report('密码不正确，请重新输入', failed: true);
      } else {
        _report(
          describeFailure(
            context,
            error,
            stack,
            action: '清除全部数据',
            kind: 'account_clear_cloud',
            kept: '账号保留，自动同步已暂停',
            next: '可以检查网络后重试清除',
          ),
          failed: true,
          retry: _clearAllData,
        );
      }
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '清除全部数据',
          kind: 'account_clear_cloud',
          kept: '账号保留',
          next: '可以重试清除，再检查同步状态',
        ),
        failed: true,
        retry: _clearAllData,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (_busy) return;
    final account = AppScope.of(context).accountServices.account;
    // 即刻收按账号标识记余额，删号之后这份积分无人可用；确认删除之前先读一次
    // 余额，只在已确认登录方式的账号上尝试。旧版实例没有购买接口、未确认登录
    // 方式的账号会收到 403，这些情况都按余额未知处理，不阻塞删除。
    int? balancePoints;
    if (_snapshot?.contactVerified == true) {
      final epoch = account.identityEpoch;
      setState(() => _busy = true);
      try {
        final overview = await account.quotaPurchases();
        // 余额暂时查不到时按未知处理，不拿 0 去说明剩余积分。
        balancePoints = overview.balanceUnavailable
            ? null
            : overview.balancePoints;
      } catch (_) {
        // 读不到余额只影响提示，删除流程照常继续。
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      // 读取期间换了账号或实例：这份余额不属于要删除的账号，回到页面重新来过。
      if (!mounted || account.identityEpoch != epoch) return;
    }
    final password = await askDeleteAccountPassword(
      context,
      remainingPoints: balancePoints,
    );
    if (password == null || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final scope = AppScope.of(context);
      await scope.accountServices.account.deleteAccount(password: password);
      if (!mounted || scope.managesSpaces) return;
      await scope.accountServices.sync.clearState();
      _report('账号与云端数据已删除；本机记录仍在');
      await _load();
    } on ServerProblem catch (error, stack) {
      if (!mounted) return;
      if (error.code == 'invalid_credentials') {
        // 只是重新认证失败：会话与页面保持原样，可以再输入一次密码。
        _report('密码不正确；账号与云端数据没有改动，登录状态保留', failed: true);
      } else {
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
      }
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
    if (value) {
      final confirmed = await confirmEnableAutoSync(
        context,
        accountLabel: _snapshot?.displayLabel ?? '',
      );
      if (!confirmed || !mounted) return;
    }
    try {
      await AppScope.of(context).accountServices.account.setAutoSync(value);
      if (!mounted) return;
      setState(
        () => _snapshot = AccountSnapshot(
          serverBaseUrl: _snapshot?.serverBaseUrl ?? '',
          session: _snapshot?.session,
          autoSync: value,
          usesDefaultServer: _snapshot?.usesDefaultServer ?? false,
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

  /// 聊天额度按积分显示：服务端只报计费 token，折算比例由 `tokens_per_point` 给出。
  /// 旧版服务端没有这一项时退回 token，避免把“不知道比例”显示成 0 积分。
  String _chatQuotaText() {
    final quota = _quota;
    if (quota == null) return '额度暂时无法读取';
    final ratio = quota.tokensPerPoint;
    if (ratio == null) {
      return '聊天今日已用 ${quota.usedTokens} token · '
          '每日免费额度 ${quota.dailyTokens} token';
    }
    return '聊天今日已用 ${quotaPoints(quota.usedTokens, ratio)} 积分 · '
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
      header: const ZhixinHeader(title: Text('账号与云同步'), showBack: true),
      // 首读期间保留标题栏，内容用与卡片同高的骨架占位。
      child: _loading
          ? ListView(
              padding: theme.space.pageInsets(bottom: 96),
              children: const [ListSkeleton(rows: 3, rowHeight: 96)],
            )
          : _content(context),
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
              ? InlineNotice(message: _notice!, onRetry: _noticeRetry)
              : Padding(
                  padding: EdgeInsets.only(bottom: theme.space.md),
                  child: Text(_notice!, style: theme.text.bodySmall),
                ),
        if (_spaces.isNotEmpty) ..._localSpaces(context),
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

  List<Widget> _localSpaces(BuildContext context) {
    final scope = AppScope.of(context);
    return [
      const SectionHeading(title: '本机空间'),
      for (final space in _spaces)
        forui.FTile(
          title: Text(
            space.id == scope.spaceId ? '${space.label}（当前）' : space.label,
          ),
          subtitle: Text(
            '${(space.bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
          ),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _busy ? null : () => _deleteLocalSpace(space),
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
    if (!confirmed || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await scope.deleteLocalSpace(space.id);
      if (mounted && space.id != scope.spaceId) await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '删除本机空间',
          kind: 'account_delete_local_space',
          kept: '云端数据保留',
          next: '可以稍后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Widget> _loggedOut(BuildContext context) {
    final theme = context.zhixin;
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              forui.FTextField(
                control: .managed(controller: _identifier),
                keyboardType: TextInputType.emailAddress,
                label: const Text('邮箱'),
              ),
              SizedBox(height: theme.space.gap),
              if (!_showReset) ...[
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
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy
                          ? null
                          : () {
                              setState(() {
                                _showReset = true;
                                _codeSent = false;
                                _clearResendCooldown();
                              });
                              _report('先点“发送验证码”，再填写邮件里的六位数字');
                            },
                      child: const Text('忘记密码'),
                    ),
                  ],
                ),
              ] else ...[
                if (_codeSent) ...[
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
                    _sendCodeButton(send: _sendResetCode),
                    if (_codeSent)
                      forui.FButton(
                        variant: forui.FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _busy ? null : _resetPassword,
                        child: const Text('重设密码'),
                      ),
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy
                          ? null
                          : () => setState(() {
                              _showReset = false;
                              _codeSent = false;
                              _clearResendCooldown();
                              _resetCode.clear();
                              _newPassword.clear();
                            }),
                      child: const Text('返回登录'),
                    ),
                  ],
                ),
                if (_codeSent) ...[
                  SizedBox(height: theme.space.sm),
                  Text(
                    '没收到先看垃圾邮件；同一条登录方式一分钟内只能发一封，反复重发要等几小时。',
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
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
                onChange: _busy ? null : _setAutoSync,
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
                if (_codeSent) SizedBox(height: theme.space.md),
                if (_codeSent)
                  forui.FTextField(
                    control: .managed(controller: _verifyCode),
                    keyboardType: TextInputType.number,
                    label: const Text('邮件里的六位验证码'),
                  ),
                if (_codeSent) SizedBox(height: theme.space.md),
                Wrap(
                  spacing: theme.space.sm,
                  runSpacing: theme.space.sm,
                  children: [
                    _sendCodeButton(send: _sendVerification),
                    if (_codeSent)
                      forui.FButton(
                        variant: forui.FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _busy ? null : _confirmVerification,
                        child: const Text('确认'),
                      ),
                  ],
                ),
                if (_codeSent) ...[
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
                  onPress: _busy || sync.syncing
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
      ..._devicesSection(context),
      SectionHeading(
        title: '模型额度',
        subtitle: '知新服务按账号统计用量，聊天按积分显示，嵌入按 token 显示，两者各有每日免费额度。',
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_chatQuotaText(), style: theme.text.bodyMedium),
              // 嵌入额度按原始 token 显示，不用积分单位；旧版服务端两项都读作 0，
              // 这时不显示这一行。
              if ((_quota?.embeddingDailyTokens ?? 0) > 0 ||
                  (_quota?.embeddingUsedTokens ?? 0) > 0)
                Text(
                  embeddingQuotaText(
                    usedTokens: _quota?.embeddingUsedTokens ?? 0,
                    dailyTokens: _quota?.embeddingDailyTokens,
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
          enabled: !_busy,
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
        onPress: _busy ? null : _clearAllData,
      ),
      SizedBox(height: theme.space.sm),
      forui.FTile(
        variant: forui.FItemVariant.destructive,
        prefix: const LeadingIcon(FLucideIcons.userX, tone: TagTone.muted),
        title: const Text('删除账号'),
        subtitle: const Text('删除账号、云端数据及这个账号的本机空间。'),
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
                  '${_maskedDeviceId(device.deviceId)} · ${_deviceSeen(device.lastSeen)}',
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
            onPress: _busy ? null : () => _renameDevice(device),
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
    if (_busy) return;
    final alias = await promptDeviceAlias(
      context,
      currentAlias: device.trimmedAlias,
    );
    if (alias == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.sync
          .renameDevice(device.deviceId, alias);
      if (!mounted) return;
      final trimmed = alias.trim();
      _report(trimmed.isEmpty ? '已清除这台设备的别名' : '已把设备名改为“$trimmed”');
      // 改名接口返回的设备对象已经替换缓存里这一行，重绘列表现出来新的别名。
      setState(() {});
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '改设备名',
          kind: 'account_device_rename',
          kept: '设备名没有改动',
          next: '可以稍后再试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 设备标识只露前 8 位，短的标识原样显示。
  static String _maskedDeviceId(String deviceId) {
    final value = deviceId.trim();
    return value.length <= 8 ? value : value.substring(0, 8);
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
