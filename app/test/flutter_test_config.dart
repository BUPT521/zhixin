import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/platform/prompt_assets.dart';

import 'support/drift_warning_guard.dart';

/// 提示词读取在整个测试进程里只做一次；没有这一步，构建器会拒绝生成提示。
///
/// drift 按运行时类型计数打印的“开了多个库”告警在这里换成按执行器判断，
/// 每组用例开始时检查一次，见 `support/drift_warning_guard.dart`。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installDriftWarningGuard();
  setUp(expectNoSharedDriftExecutor);
  TestWidgetsFlutterBinding.ensureInitialized();
  await PromptAssets.load();
  await testMain();
}
