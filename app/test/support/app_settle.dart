import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/db/database_gate.dart';

/// 让真异步区推进一小段，同时等应用自己的访问队列清空。
///
/// 页面读取、回答的兜底收尾与提示都在真异步区里跑完，假时间里推进不到；队列
/// 空着时只走这一小段真实时间。数据库访问都经过应用根的访问队列，队列空下来
/// 就说明界面这一轮的读写已经结束，不必按固定时长反复等。
Future<void> advanceAsync(
  WidgetTester tester,
  DatabaseGate? gate,
  Duration slice,
) async {
  await tester.runAsync(() async {
    if (gate != null && !gate.idle) {
      try {
        await gate.whenIdle().timeout(slice);
        return;
      } on TimeoutException {
        // 这一轮没有放完，下面照常让出一小段时间，下一轮画完帧再等。
      }
    }
    await Future<void>.delayed(slice);
  });
}

/// 推进 [rounds] 帧，逐帧等访问队列清空。
///
/// 帧的时间用来让界面发起读取、收起过渡动画，也让防抖与提示的定时器到期；
/// 真实时间只用来让读取走完，队列空着时每帧很短。
Future<void> settleFrames(
  WidgetTester tester,
  AppScopeState? scope, {
  int rounds = 12,
  Duration frame = const Duration(milliseconds: 100),
  Duration slice = const Duration(milliseconds: 5),
}) async {
  final gate = scope?.testing.gate;
  for (var round = 0; round < rounds; round++) {
    await tester.pump(frame);
    await advanceAsync(tester, gate, slice);
  }
}
