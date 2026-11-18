import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/domain/models/capacity.dart';
import 'package:zhixin/domain/models/time_values.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/ui/format.dart';

import '../support/app_scope_teardown.dart';
import '../support/telemetry.dart';

/// 容量面板改成订阅之后，事项、课表与预约的写入由数据层重读（ADR-0014）。
///
/// ADR-0014 的实施结果里点名“容量面板的订阅路径要先在页面测试里补一条”，
/// 所以第一条用例走真实入口：底栏“安排” → “这周能做什么”，面板打开之后不再
/// 点“重新估算”，数字、空档与说明都随订阅更新；整库恢复之后回到备份时的数据。
///
/// 面板本身只算“这一周”，没有换周入口，因此第二条用例只测它使用的那条订阅
/// `CapacityService.watchThisWeek`：用可变的时钟跨过周一，写入之后重读按新的
/// 一周计算，旧周的结果不会写回。取舍是这一条不经界面，换来的是不必为“跨周”
/// 另造一个界面上并不存在的入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-capacity-live-');
    await disableTelemetryForTests(directory.path);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  tearDown(() async {
    await closeAppScope(scope, directory);
    scope = null;
  });

  /// 推进到所有读取、回填与过渡动画结束。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  /// 在真异步区里写库，再 pump 到订阅的重读回填完成。
  Future<T> seed<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    await settle(tester);
    return result as T;
  }

  Future<void> openApp(WidgetTester tester, {Clock? clock}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(ZhixinApp(clock: clock));
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await settle(tester);
  }

  /// 从安排页打开容量面板。
  Future<void> openCapacitySheet(WidgetTester tester) async {
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);
  }

  testWidgets('写入事项、课表与预约之后，容量面板随订阅更新，恢复后回到备份时的数据', (tester) async {
    // 2026-11-16 是周一：本周从今天算到周日，共 7 天。
    await openApp(tester, clock: () => DateTime(2026, 11, 16, 9));
    await seed(
      tester,
      () => scope!.study.capacity.setWindow(
        start: ClockTime.parse('19:00'),
        end: ClockTime.parse('19:30'),
      ),
    );
    await openCapacitySheet(tester);

    // 首读：7 天 × 30 分钟可用，没有待排事项。
    expect(find.text('本周剩余 7 天约 3.5 小时可用，待排事项0 分钟。'), findsOneWidget);
    expect(find.text('当前没有可预约的学习事项。'), findsOneWidget);

    /// 面板上每一段空档的按钮文字；面板与这里共用同一份拼法。
    Future<List<String>> slotLabels() async => (await tester.runAsync(() async {
      final plan = await scope!.study.capacity.computeThisWeek();
      return [
        for (final window in plan.candidates.single.windows)
          '${dayLabel(window.start)} '
              '${clockOf(window.start)}–${clockOf(window.end)}',
      ];
    }))!;

    // 页面之外写一个事项：需求与空档都跟着出现，不点“重新估算”。
    await seed(
      tester,
      () => scope!.testing.tasks.createItem(title: '整理笔记', estMinutes: 20),
    );
    expect(find.text('本周剩余 7 天约 3.5 小时可用，待排事项约 20 分钟。'), findsOneWidget);
    expect(find.text('整理笔记'), findsOneWidget);
    final mondaySlot = (await slotLabels()).first;
    expect(mondaySlot, startsWith('11月16日 周一'));
    expect(find.text(mondaySlot), findsOneWidget);

    // 先留一份备份，再写一节固定课表占掉周一的空档。
    final backup = File('${directory.path}/课表前.zip');
    await tester.runAsync(() async {
      await scope!.data.versions.backupRepository(backup.path);
    });
    final bytes = (await tester.runAsync(backup.readAsBytes))!;

    // 课表写入之后可用时间与空档一起变：周一的 19:00–19:30 被课表占掉。
    await seed(
      tester,
      () => scope!.testing.schedule.addTimetable(
        weekday: 1,
        startTime: '19:00',
        endTime: '19:30',
        title: '线性代数',
      ),
    );
    expect(find.text('本周剩余 7 天约 3 小时可用，待排事项约 20 分钟。'), findsOneWidget);
    expect(find.text(mondaySlot), findsNothing);
    final tuesdaySlot = (await slotLabels()).first;
    expect(tuesdaySlot, startsWith('11月17日 周二'));
    expect(find.text(tuesdaySlot), findsOneWidget);

    // 页面之外按空档预约：这一项从“没有预约”变成可调整的弹性预约。
    await seed(tester, () async {
      final item = (await scope!.testing.tasks.items(openOnly: true)).single;
      final plan = await scope!.study.capacity.computeThisWeek();
      final window = plan.candidates.single.windows.first;
      await scope!.study.capacity.book(
        item: item,
        start: window.start,
        end: window.end,
        expectedNone: true,
      );
    });
    expect(find.textContaining('预约时调整原时间'), findsOneWidget);
    expect(find.text('这次估算会把以下弹性预约算作可调整'), findsOneWidget);
    expect(find.textContaining('点它的空档后才改期'), findsOneWidget);

    // 整库恢复换掉连接：订阅跟着新连接重读，回到备份时的空档与待排数字。
    final restored = await tester.runAsync(
      () => scope!.data.versions.restore(bytes),
    );
    expect(
      restored!.isSuccess,
      isTrue,
      reason: restored.failureOrNull?.message ?? '',
    );
    await settle(tester);
    expect(find.text('本周剩余 7 天约 3.5 小时可用，待排事项约 20 分钟。'), findsOneWidget);
    expect(find.text(mondaySlot), findsOneWidget);
    expect(find.text('这次估算会把以下弹性预约算作可调整'), findsNothing);
    expect(find.textContaining('预约时调整原时间'), findsNothing);
    expect(tester.takeException(), isNull);
    // 让最后一次重读收尾，再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });

  testWidgets('跨过周一之后订阅按新的一周重算，旧周的结果不再写回', (tester) async {
    // 周六：本周只剩周六、周日两天。时钟可变，用例在运行中把它推进到下周一。
    var now = DateTime(2026, 11, 21, 9);
    await openApp(tester, clock: () => now);

    final plans = <CapacityPlan>[];
    final subscription = (await tester.runAsync(() async {
      final sub = scope!.study.capacity.watchThisWeek().listen(plans.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return sub;
    }))!;
    addTearDown(subscription.cancel);
    await settle(tester);

    expect(plans, isNotEmpty);
    expect(plans.last.from, DateTime(2026, 11, 21));
    expect(plans.last.days, 2, reason: '周六只算到本周日');

    // 跨周：时钟走到下周一，写入触发重读；这一次按新的自然周计算。
    now = DateTime(2026, 11, 23, 9);
    final beforeAdvance = plans.length;
    await seed(
      tester,
      () => scope!.testing.tasks.createItem(title: '下一周的事项', estMinutes: 30),
    );
    await settle(tester);

    expect(plans.length, greaterThan(beforeAdvance));
    expect(plans.last.from, DateTime(2026, 11, 23));
    expect(plans.last.days, 7, reason: '周一的这一周从今天算到周日，共 7 天');
    expect(plans.last.demandMinutes, 30);
    // 跨周之后不会再回填旧周（周六、两天）的结果。
    for (final plan in plans.skip(beforeAdvance)) {
      expect(plan.from, DateTime(2026, 11, 23));
      expect(plan.days, 7);
    }
    expect(tester.takeException(), isNull);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });
}
