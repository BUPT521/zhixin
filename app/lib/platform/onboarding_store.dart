import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/atomic_file.dart';

/// 当前用户须知与隐私政策的版本。
///
/// 正文改动（采集范围、第三方清单、权利与期限这类实质内容）之后加一；启动时
/// 存下的版本比它旧，就在首页上弹一次同意对话框，同意之后再恢复联网功能。
const int kTermsVersion = 1;

/// 首次启动引导停在哪一步：登录或注册、选择外观。
///
/// 用户须知的同意不是一步，点登录、注册或找回密码时用对话框询问。
enum OnboardingStage { login, appearance }

/// 设备级的引导状态：是否走完引导、回答过哪一版用户须知、是否同意、停在哪一步。
///
/// 四项都为空时是全新的安装；文件读不出来或内容损坏时按同样的默认值处理，
/// 用户重新遇到同意对话框，不会因为坏文件被当成已经同意过。
class OnboardingRecord {
  const OnboardingRecord({
    this.completed = false,
    this.termsVersion = 0,
    this.agreed = false,
    this.stage = OnboardingStage.login,
  });

  /// 已经走完引导；之后的启动直接进入首页。
  final bool completed;

  /// 用户同意过的用户须知版本；没同意过为 0。
  final int termsVersion;

  /// 是否同意用户须知与隐私政策；假表示只在本机使用。
  final bool agreed;

  /// 当前停在哪一步；进入下一步之前先写盘，重建或重开之后从这里继续。
  final OnboardingStage stage;

  /// 同意过的是不是当前版本。版本升级之后为假，需要重新同意。
  bool get consentCurrent => agreed && termsVersion >= kTermsVersion;

  OnboardingRecord copyWith({
    bool? completed,
    int? termsVersion,
    bool? agreed,
    OnboardingStage? stage,
  }) => OnboardingRecord(
    completed: completed ?? this.completed,
    termsVersion: termsVersion ?? this.termsVersion,
    agreed: agreed ?? this.agreed,
    stage: stage ?? this.stage,
  );

  @override
  String toString() =>
      'OnboardingRecord(completed: $completed, termsVersion: $termsVersion, '
      'agreed: $agreed, stage: ${stage.name})';
}

/// 引导状态存在设备级位置：应用私有目录根下的小文件，不放进账号空间。
///
/// 按 ADR-0056，退出登录会新建一个空的未登录空间，换账号又换一个空间；引导
/// 状态若按空间保存，退出登录之后会重复出现。写入照 `DiagnosticsStore` 的
/// 做法先写临时文件再改名，读失败按未完成处理。
class OnboardingStore {
  const OnboardingStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'onboarding');

  AtomicJsonFile get _file => AtomicJsonFile(path);

  /// 读当前状态；文件缺失、内容损坏或字段类型不对时都回到默认值。
  Future<OnboardingRecord> read() async {
    try {
      final data = await _file.read();
      return OnboardingRecord(
        completed: data['completed'] == true,
        termsVersion: _versionOf(data['termsVersion']),
        agreed: data['agreed'] == true,
        stage: _stageOf(data['stage']),
      );
    } on FileSystemException {
      return const OnboardingRecord();
    } catch (_) {
      return const OnboardingRecord();
    }
  }

  /// 整份写回：四个字段一起写，读改写走同一条写入队列，两个动作不会互相覆盖。
  Future<void> write(OnboardingRecord record) => _file.update((data) {
    data['completed'] = record.completed;
    data['termsVersion'] = record.termsVersion;
    data['agreed'] = record.agreed;
    data['stage'] = record.stage.name;
  });

  static int _versionOf(Object? value) {
    if (value is int && value >= 0) return value;
    if (value is num && value >= 0) return value.toInt();
    return 0;
  }

  static OnboardingStage _stageOf(Object? value) => switch (value) {
    'appearance' => OnboardingStage.appearance,
    _ => OnboardingStage.login,
  };
}
