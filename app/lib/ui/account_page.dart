import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/prefetch_service.dart';
import '../application/sync_service.dart';
import '../data/cloud/account_store.dart' show AccountIdentity;
import '../data/cloud/server_client.dart' show ServerProblem, ServerQuota;
import '../data/db/app_database.dart' show zhixinSchemaVersion;
import 'account_dialogs.dart';
import 'cloud_sync_prompts.dart';
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
  final _server = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _verifyCode = TextEditingController();
  final _resetCode = TextEditingController();
  final _newPassword = TextEditingController();

  AccountSnapshot? _snapshot;
  SyncStatus? _sync;
  ServerQuota? _quota;
  bool _loading = true;
  bool _busy = false;

  /// 登录卡与找回密码卡之间的切换；验证码发出之后在同一个位置继续输入。
  bool _showReset = false;
  bool _codeSent = false;

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
      _server.text = prewarm.snapshot.serverBaseUrl;
      _loading = false;
    }
    _load();
  }

  @override
  void dispose() {
    _server.dispose();
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
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _sync = sync;
        _quota = quota;
        _localDeviceId = localDeviceId;
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

  void _report(String message, {bool failed = false, VoidCallback? retry}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _failed = failed;
      _noticeRetry = retry;
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
      final ready = await scope.accountServices.account.checkServer();
      final matches = ready.schemaVersion == zhixinSchemaVersion;
      _report(
        matches
            ? '服务地址已保存：服务端就绪，接受 schema ${ready.schemaVersion}'
            : '服务地址已保存，但服务端接受 schema ${ready.schemaVersion}，'
                  '本机是 $zhixinSchemaVersion；两端要一起升级才能同步',
        failed: !matches,
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
      if (_server.text.trim().isNotEmpty) {
        await scope.accountServices.account.setServerBaseUrl(_server.text);
      }
      final account = scope.accountServices.account;
      final result = register
          ? await account.register(identifier: identifier, password: password)
          : await account.login(identifier: identifier, password: password);
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

  Future<void> _sendVerification() async {
    if (_busy) return;
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
      _report('验证码已经发到${identity.kindLabel}，十分钟内有效');
    } catch (error, stack) {
      if (!mounted) return;
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
    if (_busy) return;
    final identifier = _identifier.text.trim();
    if (identifier.isEmpty) {
      _report('先填写注册用的邮箱', failed: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.of(context).accountServices.account
          .requestPasswordReset(identifier);
      _report('如果这个邮箱注册并验证过，验证码已经发出；十分钟内有效');
    } catch (error, stack) {
      if (!mounted) return;
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
      // 云端历史被压缩时同步会抛出 RecloneConfirmationRequired：先说明再确认，
      // 确认之后带 confirmReclone 再跑一轮，本机数据不在未确认时被替换（3.7）。
      var confirmReclone = false;
      while (true) {
        try {
          final result = await scope.accountServices.sync.syncNow(
            confirmBaseline: confirmBaseline,
            confirmReclone: confirmReclone,
          );
          await _load();
          if (!mounted) return;
          // 重读状态之后再给结论：摘要不一致时不能声称两边已经一致，否则状态卡
          // 显示“待修复”而提示说一致（ADR-0045）。
          _report(
            result.changed
                ? '同步完成：拉取 ${result.pulledCommits} 条、推送 ${result.pushedCommits} 条提交，'
                      '上传 ${result.uploadedAssets}、下载 ${result.downloadedAssets} 个附件'
                : (_sync?.digestMismatch ?? false)
                ? '同步完成；本机与云端的内容仍不一致，按上面的说明选择修复方式'
                : '同步完成，本机与云端已经一致',
          );
          return;
        } on RecloneConfirmationRequired catch (required) {
          if (!mounted) return;
          final confirmed = await confirmSnapshotRebuild(
            context,
            localCommits: required.localCommits,
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

  /// 摘要不一致时“以云端为准修复”：按云端提交序列重新对齐这台设备。
  ///
  /// 确认之后才执行；失败说明哪一步没有完成，本机记录不清空，已同步的部分保留
  /// （同步方案 3.5：3.7 客户端落地前先按差异重放云端状态，再补传本机独有的行）。
  Future<void> _repairFromCloud() async {
    if (_busy) return;
    final confirmed = await confirmRepairFromCloud(context);
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      final result = await scope.accountServices.sync.repairFromCloud();
      // 先重读状态再给结论：提示与状态卡不能互相矛盾，重读之后“待修复”已经
      // 消失，提示才说已经重新对齐（与“立即同步”同一顺序，ADR-0045）。
      await _load();
      if (!mounted) return;
      _report(
        result.changed
            ? '已按云端修复：拉取 ${result.pulledCommits} 条、补传 '
                  '${result.pushedCommits} 条提交，本机与云端重新对齐'
            : '已按云端修复：本机与云端已经一致',
      );
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '以云端为准修复',
          kind: 'account_sync_repair_cloud',
          kept: '本机记录没有删除，已经同步的部分保留',
          next: '可以检查网络后再试',
        ),
        failed: true,
      );
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 摘要不一致时“以本机为准修复”：把云端缺少的本机记录作为基线补传。
  ///
  /// 先拉取云端的新提交，再按 3.6 的方式补传本机独有的行；确认之后才执行。
  /// 一行都没补传时说明差异只来自云端多出来的内容，界面照实说明，标记不强行
  /// 清掉（同步方案 3.5）。这个入口只补传、不删除云端已有的记录，所以云端多
  /// 出来的行不会因此消失，界面与确认框都按这条边界说明（ADR-0045）。
  Future<void> _repairFromLocal() async {
    if (_busy) return;
    final confirmed = await confirmRepairFromLocal(context);
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      final result = await scope.accountServices.sync.repairFromLocal();
      // 与“以云端为准修复”同一顺序：重读状态之后再说结论，避免提示写着已经
      // 补齐、状态卡仍停在“待修复”。
      await _load();
      if (!mounted) return;
      _report(
        result.pushedCommits > 0
            ? '已按本机修复：补传 ${result.pushedCommits} 条提交、'
                  '${result.uploadedAssets} 个附件，云端缺少的本机记录已经上传'
            : '没有找到云端缺少的本机记录；云端多出来的内容没有改动，'
                  '需要时可以改用“以云端为准修复”',
      );
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '以本机为准修复',
          kind: 'account_sync_repair_local',
          kept: '本机记录没有改动，已经同步的部分保留',
          next: '可以检查网络后再试',
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
      final scope = AppScope.of(context);
      await scope.accountServices.account.logout();
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

  Future<void> _clearCloudData() async {
    if (_busy) return;
    final password = await askDestructiveActionPassword(
      context,
      title: '清除云端数据',
      message:
          '会永久删除这个账号在服务端保存的全部整库备份、同步提交序列与附件。'
          '本机学习记录和账号会保留，清除后需要重新同步。',
      confirmLabel: '清除',
    );
    if (password == null || !mounted || _busy) return;
    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      await scope.accountServices.account.clearCloudData(password: password);
      // 云端序列已经清空，旧位置不再有意义：连位置一起删掉，下次同步按首次
      // 基线重新建立；留着位置会让“待确认”的状态与库里对不上。
      await scope.accountServices.sync.clearState(forgetPosition: true);
      // 清除之后先停掉自动同步，再问用户要不要恢复；首次同步仍会先确认。
      await scope.accountServices.account.setAutoSync(false);
      if (!mounted) return;
      final resume = await confirmEnableAutoSync(
        context,
        accountLabel: _snapshot?.displayLabel ?? '',
      );
      if (resume) {
        await scope.accountServices.account.setAutoSync(true);
        await scope.accountServices.sync.schedule(
          delay: const Duration(seconds: 1),
        );
        _report('云端数据已清除；自动同步已恢复，下次同步会先确认是否上传本机记录');
      } else {
        _report('云端数据已清除；自动同步保持暂停，需要时在“自动同步”开关里重新开启');
      }
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
            action: '清除云端数据',
            kind: 'account_clear_cloud',
            kept: '云端数据与本机记录没有改动',
            next: '可以检查网络后重试',
          ),
          failed: true,
          retry: _clearCloudData,
        );
      }
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
        retry: _clearCloudData,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final password = await askDeleteAccountPassword(context);
    if (password == null || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final scope = AppScope.of(context);
      await scope.accountServices.account.deleteAccount(password: password);
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
        subtitle: '默认使用项目组提供的实例，也可以改成自己的服务地址；账号与密码只用于这台设备登录。',
        action: StatusTag(
          _snapshot?.usesDefaultServer == true ? '默认地址' : '已修改',
          tone: TagTone.accent,
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
                  '只填域名时按 https 处理；正式版只接受 https 地址，'
                  '本地联调要用 http 时需要在构建时显式打开明文开关。',
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
        title: _showReset ? '找回密码' : '登录或注册',
        subtitle: _showReset
            ? '向已经验证的邮箱发一封六位验证码，验证之后设置新密码；其他设备会退出登录。'
            : '登录之后可以上传整库备份、在多台设备之间同步，并使用知新服务的模型额度。',
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
                    forui.FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _sendResetCode,
                      child: Text(_codeSent ? '重新发送' : '发送验证码'),
                    ),
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
                              _resetCode.clear();
                              _newPassword.clear();
                            }),
                      child: const Text('返回登录'),
                    ),
                  ],
                ),
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
                    forui.FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _sendVerification,
                      child: Text(_codeSent ? '重新发送' : '发送验证码'),
                    ),
                    if (_codeSent)
                      forui.FButton(
                        variant: forui.FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _busy ? null : _confirmVerification,
                        child: const Text('确认'),
                      ),
                  ],
                ),
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
                SizedBox(height: theme.space.xs),
                Text(
                  '上次同步比较整库摘要时发现两边内容不同。可以选一边为准修复：'
                  '以云端为准会按云端重新对齐这台设备，以本机为准会把云端缺少的'
                  '本机记录补传上去；云端多出来的记录不会被删掉，需要的话在仍有'
                  '这些记录的设备上删除。修复只改记录，不影响登录状态与其他设备的'
                  '账号。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: theme.space.sm),
                Wrap(
                  spacing: theme.space.sm,
                  runSpacing: theme.space.sm,
                  children: [
                    forui.FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy || sync?.syncing == true
                          ? null
                          : _repairFromCloud,
                      child: const Text('以云端为准修复'),
                    ),
                    forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy || sync?.syncing == true
                          ? null
                          : _repairFromLocal,
                      child: const Text('以本机为准修复'),
                    ),
                  ],
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
        subtitle:
            '知新服务按账号计每天可用的 token，聊天与语义索引的嵌入分开计；额度用完时可以改用自己的 API Key，或等次日重置。',
      ),
      forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _quota == null
                    ? '额度暂时无法读取'
                    : '聊天今日已用 ${_quota!.usedTokens} / ${_quota!.dailyTokens} token',
                style: theme.text.bodyMedium,
              ),
              // 旧版服务端不返回嵌入额度，读作 0，这时不显示这一行。
              if ((_quota?.embeddingDailyTokens ?? 0) > 0)
                Text(
                  '嵌入今日已用 ${_quota!.embeddingUsedTokens} / '
                  '${_quota!.embeddingDailyTokens} token',
                  style: theme.text.bodyMedium,
                ),
              SizedBox(height: theme.space.xs),
              Text(
                _quota == null
                    ? '可以稍后重新进入这一页；备份与同步不受影响。'
                    : '按 ${_quota!.day} 统计，重置时间以服务端时区为准。',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
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
