import 'dart:async';

import '../data/cloud/server_client.dart' show ServerProblem;
import 'account_service.dart';
import 'sync_service.dart';

/// 账号页上互斥的一次用户操作。
///
/// 登录、验证码、重设密码、删号、清云、设备改名与额度购买原先共用页面上的一个
/// `_busy` 与一个 `_codeSent`：换一类操作会把所有按钮一起禁用，两类验证码又共用
/// 同一个“已经发出”的标记，确认登录方式的输入框会被重设密码那一次顶掉（A30）。
enum AccountAction {
  sendIdentityCode,
  confirmIdentity,
  sendResetCode,
  resetPassword,
  sync,
  rebuildCloud,
  logout,
  clearAllData,
  deleteAccount,
  deleteLocalSpace,
  renameDevice,
}

/// 一类账号操作的影响说明：动作名、诊断种类、失败之后保留了什么与下一步做什么。
///
/// 这些句子原先散在账号页每个失败分支里，“登录状态没有改动”这类说法抄了四五遍；
/// 现在按操作写一次，页面只把它交给 `describeFailure`（A30）。
class AccountActionCopy {
  const AccountActionCopy({
    required this.action,
    required this.kind,
    required this.kept,
    required this.next,
  });

  /// 说明里的动作名，例如“发送验证码”。
  final String action;

  /// 诊断记录的种类。
  final String kind;

  /// 失败之后保留了什么。
  final String kept;

  /// 下一步可以做什么。
  final String next;
}

/// 按操作取影响说明。
AccountActionCopy accountActionCopy(AccountAction action) => switch (action) {
  AccountAction.sendIdentityCode => const AccountActionCopy(
    action: '发送验证码',
    kind: 'account_identifier_code',
    kept: '登录状态没有改动',
    next: '可以检查邮箱与服务地址后重试',
  ),
  AccountAction.confirmIdentity => const AccountActionCopy(
    action: '确认登录方式',
    kind: 'account_identifier_confirm',
    kept: '登录状态没有改动',
    next: '可以重新获取验证码再试',
  ),
  AccountAction.sendResetCode => const AccountActionCopy(
    action: '发送重设验证码',
    kind: 'account_reset_code',
    kept: '登录状态与密码没有改动',
    next: '可以检查邮箱与服务地址后重试',
  ),
  AccountAction.resetPassword => const AccountActionCopy(
    action: '重设密码',
    kind: 'account_reset',
    kept: '密码没有改动',
    next: '可以重新获取验证码再试',
  ),
  AccountAction.sync => const AccountActionCopy(
    action: '同步',
    kind: 'account_sync',
    kept: '本机记录没有改动，已经同步的部分保留',
    next: '可以检查网络后重试',
  ),
  AccountAction.rebuildCloud => const AccountActionCopy(
    action: '重建云端',
    kind: 'account_sync_rebuild',
    kept: '本机记录没有删除；云端可能已经清空，再试一次会按首次同步重新对齐',
    next: '可以检查网络后再试',
  ),
  AccountAction.logout => const AccountActionCopy(
    action: '退出登录',
    kind: 'account_logout',
    kept: '登录状态没有改动',
    next: '可以再试一次',
  ),
  AccountAction.clearAllData => const AccountActionCopy(
    action: '清除全部数据',
    kind: 'account_clear_cloud',
    kept: '账号保留',
    next: '可以重试清除，再检查同步状态',
  ),
  AccountAction.deleteAccount => const AccountActionCopy(
    action: '删除账号',
    kind: 'account_delete',
    kept: '账号与云端数据没有改动',
    next: '可以检查网络后重试',
  ),
  AccountAction.deleteLocalSpace => const AccountActionCopy(
    action: '删除本机空间',
    kind: 'account_delete_local_space',
    kept: '云端数据保留',
    next: '可以稍后重试',
  ),
  AccountAction.renameDevice => const AccountActionCopy(
    action: '改设备名',
    kind: 'account_device_rename',
    kept: '设备名没有改动',
    next: '可以稍后再试',
  ),
};

/// 账号页的操作状态：哪一类流程在跑、验证码发给了哪一类流程、重发还要等多久。
///
/// 与原先的一个布尔值相比，这里写清“谁在跑”与“验证码属于哪一次”，页面据此
/// 只禁用真正冲突的按钮（A30）。
class AccountActionState {
  const AccountActionState({this.running, this.codeSent, this.resendWait = 0});

  /// 没有操作在跑、没有验证码在等输入、没有冷却。
  static const idle = AccountActionState();

  /// 正在跑的那一类流程；没有在跑时为空。
  final AccountAction? running;

  /// 验证码已经发出、正在等输入的那一类流程。
  final AccountAction? codeSent;

  /// 重发倒计时剩余秒数；0 表示现在就可以再发。
  final int resendWait;

  /// 有流程在跑：其余按钮随之禁用。
  bool get busy => running != null;

  /// 正在重发冷却里：发送按钮禁用并写出还要等多久。
  bool get cooling => resendWait > 0;

  /// 这一类流程的验证码已经发出，输入框与确认按钮据此出现。
  bool codeSentFor(AccountAction action) => codeSent == action;

  AccountActionState withRunning(AccountAction? action) => AccountActionState(
    running: action,
    codeSent: codeSent,
    resendWait: resendWait,
  );

  AccountActionState withCodeSent(AccountAction? action) => AccountActionState(
    running: running,
    codeSent: action,
    resendWait: resendWait,
  );

  AccountActionState withResendWait(int seconds) => AccountActionState(
    running: running,
    codeSent: codeSent,
    resendWait: seconds,
  );

  @override
  bool operator ==(Object other) =>
      other is AccountActionState &&
      other.running == running &&
      other.codeSent == codeSent &&
      other.resendWait == resendWait;

  @override
  int get hashCode => Object.hash(running, codeSent, resendWait);

  @override
  String toString() =>
      'AccountActionState(running: $running, codeSent: $codeSent, '
      'resendWait: $resendWait)';
}

/// 一次账号操作的结果：成功时给页面一句说明，校验没过时给一句就地提示。
class AccountActionResult {
  const AccountActionResult.ok(
    this.message, {
    this.reload = false,
    this.clearDigestMismatch = false,
  }) : failed = false;

  /// 输入还没满足就停下：不改任何状态，只在页面上提示。
  const AccountActionResult.rejected(this.message)
    : failed = true,
      reload = false,
      clearDigestMismatch = false;

  /// 不算失败、但也不是一次成功操作的一句说明：并发冲突这类“稍后再试”用它，
  /// 与原来的就地一行小字一致。
  const AccountActionResult.notice(this.message)
    : failed = false,
      reload = false,
      clearDigestMismatch = false;

  final String message;
  final bool failed;

  /// 成功之后要重读账号摘要：确认登录方式、重设密码、退出、删号与清云都改账号状态。
  final bool reload;

  /// 成功之后摘掉账号页状态卡上的“待修复”。
  final bool clearDigestMismatch;
}

/// 账号页的操作顺序、影响说明与重发冷却；页面只留确认框与渲染。
///
/// 纯 Dart：定时器到点经 [onChanged] 通知页面重绘，页面不再自己记“在忙”“验证码
/// 已经发出”与倒计时三份状态（A30）。[clearAllData] 与 [deleteLocalSpace] 是应用根
/// 上的入口，由页面注入，本类只决定何时调用、调用之后读什么。
class AccountActions {
  AccountActions({
    required this.account,
    required this.sync,
    required this.clearAllData,
    required this.deleteLocalSpace,
    this.onChanged,
  });

  final AccountService account;
  final SyncService sync;

  /// 应用根的“清空本机与云端”，要当前密码。
  final Future<void> Function(String password) clearAllData;

  /// 应用根的“删除某一份本机空间”。
  final Future<void> Function(String spaceId) deleteLocalSpace;

  /// 状态变化时通知页面重绘。
  void Function()? onChanged;

  /// 服务端默认的冷却时间；成功响应不带 `Retry-After`，先按这个值禁用按钮。
  static const resendCooldownSeconds = 60;

  AccountActionState _state = AccountActionState.idle;
  Timer? _ticker;

  AccountActionState get state => _state;

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    onChanged = null;
  }

  void _set(AccountActionState next) {
    if (next == _state) return;
    _state = next;
    onChanged?.call();
  }

  // —— 状态机的三个入口，页面在一次流程的前后各调一次 ——

  /// 开始一次流程：其余按钮随之禁用。
  void begin(AccountAction action) => _set(_state.withRunning(action));

  /// 一次流程结束；验证码与冷却状态保留，等用户接着输入。
  void end() => _set(_state.withRunning(null));

  /// 服务端说还要等多久就按这个秒数继续禁用按钮；其余失败不动倒计时。
  void cooldownFrom(Object error) {
    if (error is! ServerProblem) return;
    final seconds = error.retryAfterSeconds;
    if (seconds == null || seconds <= 0) return;
    _startCooldown(seconds);
  }

  /// 登录与找回密码之间切换时清掉：另一个入口的冷却不该挡住这一次发送。
  void clearCooldown() {
    _ticker?.cancel();
    _ticker = null;
    _set(AccountActionState(codeSent: _state.codeSent, resendWait: 0));
  }

  /// 登录与找回密码之间切换时一并忘掉验证码已经发出。
  void clearCode() =>
      _set(const AccountActionState().withResendWait(_state.resendWait));

  void _startCooldown(int seconds) {
    _ticker?.cancel();
    _ticker = null;
    if (seconds <= 0) {
      _set(_state.withResendWait(0));
      return;
    }
    _set(_state.withResendWait(seconds));
    // 收信预算用完时要等几个小时，按秒刷新只会白白唤醒页面，长等待按半分钟走。
    final step = seconds > 120 ? 30 : 1;
    _ticker = Timer.periodic(Duration(seconds: step), (timer) {
      final next = _state.resendWait - step;
      if (next <= 0) {
        timer.cancel();
        _ticker = null;
        _set(_state.withResendWait(0));
      } else {
        _set(_state.withResendWait(next));
      }
    });
  }

  // —— 验证码与密码 ——

  /// 给指定登录方式发验证码；发出之后按服务端的冷却时间禁用重发。
  Future<AccountActionResult> sendIdentityCode({
    required String identityId,
    required String identifier,
  }) async {
    await account.requestIdentityVerification(identityId);
    _set(_state.withCodeSent(AccountAction.sendIdentityCode));
    _startCooldown(resendCooldownSeconds);
    return AccountActionResult.ok('验证码已经发到 $identifier，十分钟内有效');
  }

  /// 用六位验证码确认登录方式；确认之后账号摘要要重读。
  Future<AccountActionResult> confirmIdentity({
    required String identityId,
    required String kindLabel,
    required String code,
  }) async {
    if (code.length != 6) {
      return const AccountActionResult.rejected('填写邮件里的六位验证码');
    }
    await account.confirmIdentityVerification(identityId, code);
    _set(_state.withCodeSent(null).withResendWait(0));
    return AccountActionResult.ok(
      '$kindLabel已经确认；忘记密码时可以收到重设验证码',
      reload: true,
    );
  }

  /// 向登记的登录方式发重设验证码；账号不存在或还没确认时服务端也返回成功。
  Future<AccountActionResult> sendResetCode({
    required String identifier,
  }) async {
    if (identifier.isEmpty) {
      return const AccountActionResult.rejected('先填写注册用的邮箱');
    }
    await account.requestPasswordReset(identifier);
    _set(_state.withCodeSent(AccountAction.sendResetCode));
    _startCooldown(resendCooldownSeconds);
    return AccountActionResult.ok('如果这个邮箱注册并验证过，验证码已经发出；十分钟内有效');
  }

  /// 用验证码重设密码：成功后本机登录状态被清掉，页面重读账号摘要。
  Future<AccountActionResult> resetPassword({
    required String identifier,
    required String code,
    required String password,
  }) async {
    if (identifier.isEmpty) {
      return const AccountActionResult.rejected('先填写注册用的邮箱');
    }
    if (code.length != 6) {
      return const AccountActionResult.rejected('填写邮件里的六位验证码');
    }
    if (password.length < 8) {
      return const AccountActionResult.rejected('新密码至少 8 位');
    }
    await account.resetPassword(
      identifier: identifier,
      code: code,
      newPassword: password,
    );
    _ticker?.cancel();
    _ticker = null;
    _set(AccountActionState.idle);
    return AccountActionResult.ok('密码已经重设，请用新密码登录；其他设备需要重新登录', reload: true);
  }

  // —— 设备、云端与账号 ——

  /// 改一台设备的别名；成功之后同步服务缓存里这一行已经是新的别名。
  Future<AccountActionResult> renameDevice({
    required String deviceId,
    required String alias,
  }) async {
    await sync.renameDevice(deviceId, alias);
    final trimmed = alias.trim();
    return AccountActionResult.ok(
      trimmed.isEmpty ? '已清除这台设备的别名' : '已把设备名改为“$trimmed”',
    );
  }

  /// 以本机为准重建云端：清空服务端的提交序列，再把本机当前投影整份上传。
  ///
  /// 密码错误与并发冲突给各自的下一步，其余失败由页面按 [AccountAction.rebuildCloud]
  /// 的影响说明提示（A30）。
  Future<AccountActionResult> rebuildCloud({required String password}) async {
    final SyncResult result;
    try {
      result = await sync.rebuildCloudFromLocal(password: password);
    } on ServerProblem catch (error) {
      if (error.isConflict) {
        return const AccountActionResult.notice('该账号还有云端操作在进行，请稍后重试');
      }
      if (error.code == 'invalid_credentials') {
        return const AccountActionResult.rejected('密码不正确；云端与本机数据都没有改动');
      }
      rethrow;
    }
    return AccountActionResult.ok(
      result.pushedCommits > 0
          ? '已按本机重建云端：上传 ${result.pushedCommits} 条提交、'
                '${result.uploadedAssets} 个附件；其他设备下次同步会重新上传'
                '它们本机的内容'
          : '云端已经按本机当前内容重建，没有需要上传的改动',
      reload: true,
      clearDigestMismatch: true,
    );
  }

  /// 退出当前设备：[managesSpaces] 为真时登录会换空间，本页随之卸载，返回空。
  Future<AccountActionResult?> logout({
    required bool deleteSpace,
    required bool managesSpaces,
  }) async {
    await account.logout(deleteSpace: deleteSpace);
    if (managesSpaces) return null;
    // 退出之后同步位置不再继续推进，不能一直挡住“清理历史”；位置与账号归属
    // 保留，重新登录同一账号时仍从原位置继续增量同步（同步方案 3.3）。
    await sync.clearState();
    return AccountActionResult.ok(
      '已退出登录；本机记录仍在，云端数据保留，重新登录同一账号可以接着同步',
      reload: true,
    );
  }

  /// 清空当前本机空间与这个账号在服务端的数据，账号与登录状态保留。
  Future<AccountActionResult?> clearData({
    required String password,
    required bool managesSpaces,
  }) async {
    try {
      await clearAllData(password);
    } on ServerProblem catch (error) {
      if (error.isConflict) {
        return const AccountActionResult.notice('该账号还有云端操作在进行，请稍后重试');
      }
      if (error.code == 'invalid_credentials') {
        return const AccountActionResult.rejected('密码不正确，请重新输入');
      }
      rethrow;
    }
    if (managesSpaces) return null;
    return AccountActionResult.ok('本机与云端数据已清除，登录状态保留', reload: true);
  }

  /// 删除账号之前读一次积分余额；读不到按未知处理，不阻塞删除。
  ///
  /// 即刻收按账号标识记余额，删号之后这份积分无人可用；只在已确认登录方式的账号
  /// 上尝试，旧版实例与未确认登录方式的账号会收到 403，这些情况都按余额未知处理。
  Future<int?> remainingPointsBeforeDelete({
    required bool contactVerified,
  }) async {
    if (!contactVerified) return null;
    final epoch = account.identityEpoch;
    try {
      final overview = await account.quotaPurchases();
      // 读取期间换了账号或实例：这份余额不属于要删除的账号。
      if (account.identityEpoch != epoch) return null;
      return overview.balanceUnavailable ? null : overview.balancePoints;
    } catch (_) {
      // 读不到余额只影响提示，删除流程照常继续。
      return null;
    }
  }

  /// 删除账号与云端数据；密码错误时登录状态保留，可以再输入一次。
  Future<AccountActionResult?> deleteAccount({
    required String password,
    required bool managesSpaces,
  }) async {
    try {
      await account.deleteAccount(password: password);
    } on ServerProblem catch (error) {
      // 只是重新认证失败：会话与页面保持原样，可以再输入一次密码。
      if (error.code == 'invalid_credentials') {
        return const AccountActionResult.rejected('密码不正确；账号与云端数据没有改动，登录状态保留');
      }
      rethrow;
    }
    if (managesSpaces) return null;
    await sync.clearState();
    return AccountActionResult.ok('账号与云端数据已删除；本机记录仍在', reload: true);
  }

  /// 删除一份本机空间；云端数据保留。
  Future<AccountActionResult> deleteLocalSpaceById({
    required String spaceId,
    required String label,
  }) async {
    await deleteLocalSpace(spaceId);
    return AccountActionResult.ok('已删除本机空间“$label”');
  }
}
