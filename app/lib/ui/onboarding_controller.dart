import 'package:flutter/foundation.dart';

import '../platform/onboarding_store.dart';

export '../platform/onboarding_store.dart' show OnboardingStage;

/// 启动时按当前状态决定的去向。
enum OnboardingEntry {
  /// 已经完成引导，直接进入首页。
  home,

  /// 首页上补一次同意：老用户升级，或者用户须知版本变了要重新同意。
  termsOnly,

  /// 完整两步：登录或注册、选择外观。
  full,
}

/// 首次启动引导的状态与步骤推进。
///
/// 用户须知的同意不占一步：点登录、注册或找回密码时由对话框询问（见
/// `onboarding_consent.dart`），所以这里只有登录与外观两步。控制器由应用根部
/// 持有，不放进引导页自己的 State：第一次登录会换本机空间，`MaterialApp` 整棵树
/// 按新的 `GlobalKey` 重建，页面会被重新创建，而控制器还在。进入下一步之前先把
/// 步骤写进 [OnboardingStore]：登录会在请求途中换空间，等登录返回再记已经来不及，
/// 重建之后按记下的步骤与当前登录态继续。
class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required this.store,
    required this.entry,
    required OnboardingRecord record,
    required bool signedIn,
    required bool telemetryEnabled,
  }) : _record = record,
       _stage = _initialStage(record, entry, signedIn) {
    _telemetryEnabled = telemetryEnabled;
  }

  /// 按状态决定走完整引导、在首页补同意还是直接进首页。
  ///
  /// [existingUser] 是升级前已经用过应用的判断：没有完成标记，但已经登录、本机
  /// 库非空或已经看过匿名统计说明时，按老用户处理，在首页上补一次同意。
  static OnboardingEntry entryFor(
    OnboardingRecord record, {
    required bool existingUser,
  }) {
    if (record.completed) {
      return record.termsVersion >= kTermsVersion
          ? OnboardingEntry.home
          : OnboardingEntry.termsOnly;
    }
    // 回答过当前版本、只是没走完引导：接着走，不再问一次。
    if (record.termsVersion >= kTermsVersion) return OnboardingEntry.full;
    return existingUser ? OnboardingEntry.termsOnly : OnboardingEntry.full;
  }

  /// 重建或重开之后从哪一步继续。
  ///
  /// 记下的步骤优先，登录态与须知状态在它之上校正：换空间重建之后账号已经登录，
  /// 就直接到外观；回答过当前版本并选了只在本机的设备没有登录这一步。
  static OnboardingStage _initialStage(
    OnboardingRecord record,
    OnboardingEntry entry,
    bool signedIn,
  ) {
    if (entry != OnboardingEntry.full) return OnboardingStage.login;
    // 已经回答过当前版本且选了只在本机：上一轮跳过了登录，这次也不显示。
    if (record.termsVersion >= kTermsVersion && !record.agreed) {
      return OnboardingStage.appearance;
    }
    if (signedIn) return OnboardingStage.appearance;
    return record.stage == OnboardingStage.appearance
        ? OnboardingStage.appearance
        : OnboardingStage.login;
  }

  final OnboardingStore store;
  final OnboardingEntry entry;

  OnboardingRecord _record;
  OnboardingStage _stage;
  late bool _telemetryEnabled;
  bool _finished = false;

  OnboardingRecord get record => _record;

  OnboardingStage get stage => _stage;

  /// 在首页补一次同意：老用户升级或者须知版本变了。
  bool get termsOnly => entry == OnboardingEntry.termsOnly;

  /// 已经走完引导；应用根部据此把首页换回来。
  bool get finished => _finished;

  /// 当前是否同意用户须知与隐私政策。
  bool get agreed => _record.agreed;

  /// 已经回答过当前版本、选了只在本机使用。
  bool get declined => _record.termsVersion >= kTermsVersion && !_record.agreed;

  /// 联网功能是否可用：同意过当前版本之后才会启动匿名上报与更新检查。
  bool get networkAllowed => _record.consentCurrent;

  /// 同意对话框里匿名使用统计的初始开关；默认开启，与 ADR-0019 一致。
  bool get telemetryEnabled => _telemetryEnabled;

  /// 进度点个数：登录与外观两段。
  int get progressCount => 2;

  /// 当前是第几段（从 0 开始）。
  int get progressIndex => _stage.index;

  set telemetryEnabled(bool value) {
    if (value == _telemetryEnabled) return;
    _telemetryEnabled = value;
    notifyListeners();
  }

  /// 同意：记下当前版本与同意，联网功能随这一条打开。
  Future<void> acceptTerms() =>
      _write(_record.copyWith(termsVersion: kTermsVersion, agreed: true));

  /// 不同意：记下已经回答过当前版本，联网功能保持关闭。
  Future<void> declineTerms() =>
      _write(_record.copyWith(termsVersion: kTermsVersion, agreed: false));

  /// 先在本机用：记下只在本机使用，直接到外观这一步。
  ///
  /// 记下的是“回答过当前版本”，不是同意，所以下次启动不会再问；之后在设置的
  /// 同意入口或登录时仍可以补上。
  Future<void> useLocally() async {
    await declineTerms();
    await _enter(OnboardingStage.appearance);
  }

  /// 登录成功之后进入外观这一步。
  ///
  /// 换空间时调用方已经卸载，推进发生在重建之后按登录态检查的这一处；不换空间
  /// 的装配（测试）里由登录表单的回调调用。
  Future<void> signedIn() async {
    if (_stage != OnboardingStage.login) return;
    await _enter(OnboardingStage.appearance);
  }

  /// 返回上一步会去的那一步；登录是第一页，没有上一步，返回空。
  OnboardingStage? get previousStage =>
      _stage == OnboardingStage.appearance ? OnboardingStage.login : null;

  /// 返回上一步；第一页由页面负责退出应用。
  ///
  /// 只改当前停留在哪一步，不把记下的步骤往回写：设备文件保存的是已经走到的
  /// 最远一步，返回之后重开应用仍从那里继续。
  void back() {
    final previous = previousStage;
    if (previous == null) return;
    _stage = previous;
    notifyListeners();
  }

  /// 往回翻到某一步；往前走由页面按各自的动作处理，不直接改步骤。
  void goTo(OnboardingStage stage) {
    if (stage == _stage || stage.index > _stage.index) return;
    _stage = stage;
    notifyListeners();
  }

  /// 走完引导：写完成标记，之后启动直接进入首页。
  Future<void> finish() async {
    await _write(_record.copyWith(completed: true));
    _finished = true;
    notifyListeners();
  }

  /// 进入某一步：先把步骤写进设备文件，再改内存里的步骤并通知界面。
  Future<void> _enter(OnboardingStage stage) async {
    if (_stage == stage) return;
    final next = _record.copyWith(stage: stage);
    await store.write(next);
    _record = next;
    _stage = stage;
    notifyListeners();
  }

  Future<void> _write(OnboardingRecord next) async {
    await store.write(next);
    _record = next;
    notifyListeners();
  }
}
