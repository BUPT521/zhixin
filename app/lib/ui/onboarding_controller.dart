import 'package:flutter/foundation.dart';

import '../platform/onboarding_store.dart';

/// 启动时按当前状态决定的去向。
enum OnboardingEntry {
  /// 已经完成引导，直接进入首页。
  home,

  /// 只补第一步：老用户升级，或者用户须知版本变了要重新同意。
  termsOnly,

  /// 完整三步：用户须知、登录、外观。
  full,
}

/// 首次启动引导当前停在第几步。
enum OnboardingStage { terms, login, appearance }

/// 首次启动引导的状态与步骤推进。
///
/// 控制器由应用根部持有，不放进引导页自己的 State：第一次登录会换本机空间，
/// `MaterialApp` 整棵树按新的 `GlobalKey` 重建，页面会被重新创建，而控制器还
/// 在，重建之后仍停在刚才那一步。每一步的完成也写进 [OnboardingStore]，进程
/// 被杀掉之后按记下的状态继续。
class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required this.store,
    required this.entry,
    required OnboardingRecord record,
    required bool signedIn,
    required bool telemetryEnabled,
  }) : _record = record,
       _stage = _initialStage(record, entry, signedIn),
       _declined =
           entry == OnboardingEntry.full &&
           record.termsVersion >= kTermsVersion &&
           !record.agreed {
    _telemetryEnabled = telemetryEnabled;
  }

  /// 按状态决定走完整引导、只补第一步还是直接进首页。
  ///
  /// [existingUser] 是升级前已经用过应用的判断：没有完成标记，但已经登录、本机
  /// 库非空或已经看过匿名统计说明时，只让老用户补第一步。
  static OnboardingEntry entryFor(
    OnboardingRecord record, {
    required bool existingUser,
  }) {
    if (record.completed) {
      return record.termsVersion >= kTermsVersion
          ? OnboardingEntry.home
          : OnboardingEntry.termsOnly;
    }
    // 已经同意过当前版本但没走完：上次在登录或外观那一步退出了，按记下的
    // 状态继续，不再让用户重读一遍须知。
    if (record.termsVersion >= kTermsVersion) return OnboardingEntry.full;
    return existingUser ? OnboardingEntry.termsOnly : OnboardingEntry.full;
  }

  static OnboardingStage _initialStage(
    OnboardingRecord record,
    OnboardingEntry entry,
    bool signedIn,
  ) {
    if (entry != OnboardingEntry.full) return OnboardingStage.terms;
    if (record.termsVersion >= kTermsVersion) {
      if (!record.agreed) return OnboardingStage.appearance;
      return signedIn ? OnboardingStage.appearance : OnboardingStage.login;
    }
    return OnboardingStage.terms;
  }

  final OnboardingStore store;
  final OnboardingEntry entry;

  OnboardingRecord _record;
  OnboardingStage _stage;
  late bool _telemetryEnabled;
  bool _termsChecked = false;
  bool _declined;
  bool _finished = false;
  OnboardingRecord get record => _record;

  OnboardingStage get stage => _stage;

  /// 只补第一步：老用户升级或者须知版本变了。
  bool get termsOnly => entry == OnboardingEntry.termsOnly;

  /// 已经走完引导；应用根部据此把首页换回来。
  bool get finished => _finished;

  /// 当前是否同意用户须知与隐私政策。
  bool get agreed => _record.agreed;

  /// 只在本机使用：用户在这一轮引导里选了“不同意”。
  bool get declined => _declined;

  /// 联网功能是否可用：同意过头像之后才会启动匿名上报与更新检查。
  bool get networkAllowed => _record.consentCurrent;

  /// 第一页的勾选框状态；返回上一步时保留。
  bool get termsChecked => _termsChecked;

  /// 第一页的匿名使用统计开关；默认开启，与 ADR-0019 一致。
  bool get telemetryEnabled => _telemetryEnabled;

  /// 进度点个数：只补第一步时只有一段。
  int get progressCount => termsOnly ? 1 : 3;

  /// 当前是第几段（从 0 开始）。
  int get progressIndex => _stage.index;

  set termsChecked(bool value) {
    if (value == _termsChecked) return;
    _termsChecked = value;
    notifyListeners();
  }

  set telemetryEnabled(bool value) {
    if (value == _telemetryEnabled) return;
    _telemetryEnabled = value;
    notifyListeners();
  }

  /// 第一步同意：记下同意的版本，进入下一步。只写状态，进度交给调用方。
  Future<void> acceptTerms() => _write(
    _record.copyWith(termsVersion: kTermsVersion, agreed: true),
  );

  /// 第一步不同意：记下已经看过当前版本，进入纯本机模式，直接跳到外观。
  Future<void> declineTerms() async {
    await _write(_record.copyWith(termsVersion: kTermsVersion, agreed: false));
    _declined = true;
  }

  /// 第一步之后：只补第一步的直接完成，完整引导进登录。
  void continueAfterTerms() {
    if (termsOnly) return;
    _stage = OnboardingStage.login;
    notifyListeners();
  }

  /// 不同意之后直接跳到第三步，不显示登录步骤。
  void skipLogin() {
    _stage = OnboardingStage.appearance;
    notifyListeners();
  }

  /// 登录成功（包括在账号页里登录）之后进入外观这一页。
  void signedIn() {
    if (_stage == OnboardingStage.appearance) return;
    _stage = OnboardingStage.appearance;
    notifyListeners();
  }

  /// 返回上一步；第一步由页面负责退出应用。
  void back() {
    if (_stage == OnboardingStage.terms) return;
    if (_stage == OnboardingStage.login) {
      _stage = OnboardingStage.terms;
      // 回到第一步时保留勾选：用户已经同意过，回来通常是改主意或看正文。
      _termsChecked = true;
    } else {
      if (termsOnly) return;
      // 主动跳过登录或不同意时没有登录这一步，回到第一步重新选。
      _stage = _record.agreed
          ? OnboardingStage.login
          : OnboardingStage.terms;
      _termsChecked = _record.agreed;
    }
    notifyListeners();
  }

  /// 走完引导：写完成标记，之后启动直接进入首页。
  Future<void> finish() async {
    await _write(_record.copyWith(completed: true));
    _finished = true;
    notifyListeners();
  }

  Future<void> _write(OnboardingRecord next) async {
    await store.write(next);
    _record = next;
    notifyListeners();
  }
}
