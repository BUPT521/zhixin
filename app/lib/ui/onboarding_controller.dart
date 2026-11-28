import 'package:flutter/foundation.dart';

import '../platform/onboarding_store.dart';

export '../platform/onboarding_store.dart' show OnboardingStage;

/// 启动时按当前状态决定的去向。
enum OnboardingEntry {
  /// 已经完成引导，直接进入首页。
  home,

  /// 只补第一步：老用户升级，或者用户须知版本变了要重新同意。
  termsOnly,

  /// 完整三步：用户须知、登录、外观。
  full,
}

/// 首次启动引导的状态与步骤推进。
///
/// 控制器由应用根部持有，不放进引导页自己的 State：第一次登录会换本机空间，
/// `MaterialApp` 整棵树按新的 `GlobalKey` 重建，页面会被重新创建，而控制器还
/// 在。进入下一步之前先把步骤写进 [OnboardingStore]：登录会在请求途中换空间，
/// 等登录返回再记已经来不及，重建之后按记下的步骤与当前登录态继续。
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
    _termsChecked = record.consentCurrent;
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

  /// 重建或重开之后从哪一步继续。
  ///
  /// 记下的步骤优先，登录态与须知状态在它之上校正：换空间重建之后账号已经
  /// 登录，就直接到外观；选过“不同意”的设备没有登录这一步；须知版本变了，
  /// 回到第一步重新同意。
  static OnboardingStage _initialStage(
    OnboardingRecord record,
    OnboardingEntry entry,
    bool signedIn,
  ) {
    if (entry != OnboardingEntry.full) return OnboardingStage.terms;
    if (record.termsVersion < kTermsVersion) return OnboardingStage.terms;
    if (!record.agreed) return OnboardingStage.appearance;
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
  late bool _termsChecked;
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

  /// 联网功能是否可用：同意过之后才会启动匿名上报与更新检查。
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
  Future<void> acceptTerms() =>
      _write(_record.copyWith(termsVersion: kTermsVersion, agreed: true));

  /// 第一步不同意：记下已经看过当前版本，进入纯本机模式，直接跳到外观。
  Future<void> declineTerms() async {
    final next = _record.copyWith(termsVersion: kTermsVersion, agreed: false);
    await _write(next);
    _declined = true;
    notifyListeners();
  }

  /// 第一步之后：只补第一步的直接完成，完整引导进登录。
  ///
  /// 进入第二步之前先写盘：登录会换空间、整棵界面重建，成功的信号是重建本身，
  /// 不能等登录返回之后再记这一步。
  Future<void> continueAfterTerms() async {
    if (termsOnly) return;
    await _enter(OnboardingStage.login);
  }

  /// 不同意之后直接跳到第三步，不显示登录步骤。
  Future<void> skipLogin() => _enter(OnboardingStage.appearance);

  /// 登录成功之后进入外观这一步。
  ///
  /// 换空间时调用方已经卸载，推进发生在重建之后按登录态检查的这一处；不换空间
  /// 的装配（测试）里由登录表单的回调调用。
  Future<void> signedIn() async {
    if (_stage != OnboardingStage.login) return;
    await _enter(OnboardingStage.appearance);
  }

  /// 返回上一步；第一步由页面负责退出应用。
  ///
  /// 只改当前停留在哪一步，不把记下的步骤往回写：设备文件保存的是已经走到的
  /// 最远一步，返回之后重开应用仍从那里继续。
  void back() {
    if (_stage == OnboardingStage.terms) return;
    if (_stage == OnboardingStage.login) {
      _stage = OnboardingStage.terms;
      // 回到第一步时保留勾选：用户已经同意过，回来通常是改主意或看正文。
      _termsChecked = true;
    } else {
      if (termsOnly) return;
      // 主动跳过登录或不同意时没有登录这一步，回到第一步重新选。
      _stage = _record.agreed ? OnboardingStage.login : OnboardingStage.terms;
      _termsChecked = _record.agreed;
    }
    notifyListeners();
  }

  /// 点顶部进度点直接切到某一步。
  ///
  /// 往后翻与按钮推进一样，先把步骤写进设备文件再改界面；往前翻只改当前停留
  /// 的位置，不把记下的步骤往回写。回到第一步时与 [back] 一样保留勾选，用户
  /// 已经同意过，回来通常是要改主意或看正文。
  Future<void> goTo(OnboardingStage stage) async {
    if (stage == _stage) return;
    if (stage.index > _stage.index) {
      await _enter(stage);
      return;
    }
    _stage = stage;
    _termsChecked = _termsChecked || _record.agreed;
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
