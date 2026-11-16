import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/platform/prompt_assets.dart';

/// 提示词读取在整个测试进程里只做一次；没有这一步，构建器会拒绝生成提示。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await PromptAssets.load();
  await testMain();
}
