import 'dart:async';
import 'dart:io';

import 'package:calendar_view/calendar_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/application/plan_week_reader.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/ui/plan_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

/// 安排页的换周读取：两次读取反序完成时，标题、日历、预约与课表都留在新周，
/// 旧结果、旧错误与旧分页结果不再写回。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-plan-week-');
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
    await scope?.db.close();
    scope = null;
    await directory.delete(recursive: true);
  });

  /// 读取还没回来的请求；用例按自己的顺序把结果交回去。
  final pending = <({DateTime weekStart, Completer<PlanWeek> completer})>[];
  late PlanWeekReader reader;

  setUp(() {
    pending.clear();
    reader = PlanWeekReader(
      read: (weekStart) {
        final completer = Completer<PlanWeek>();
        pending.add((weekStart: weekStart, completer: completer));
        return completer.future;
      },
    );
  });

  /// 交回某一次读取的结果；同一周可能有多次请求，先完成的先交回。
  void complete(DateTime weekStart, PlanWeek week) {
    final request = pending.firstWhere(
      (entry) => entry.weekStart == weekStart && !entry.completer.isCompleted,
      orElse: () => throw StateError('没有等待中的读取：$weekStart'),
    );
    request.completer.complete(week);
  }

  bool isWaiting(DateTime weekStart) => pending.any(
    (entry) => entry.weekStart == weekStart && !entry.completer.isCompleted,
  );

  /// 最近一次发出、还没有交回结果的读取；都交回之后取最后一条。
  DateTime? lastRequestedWeek() {
    final waiting = pending.where((entry) => !entry.completer.isCompleted);
    if (waiting.isNotEmpty) return waiting.last.weekStart;
    return pending.isEmpty ? null : pending.last.weekStart;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 10; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    await tester.pumpAndSettle();
  }

  /// 只装配安排页需要的部分：应用根、主题与提示宿主；不经过底栏。
  Future<void> openPlanPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final themeMode = ThemeModeController();
    addTearDown(themeMode.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          title: '知新',
          debugShowCheckedModeBanner: false,
          theme: zhixinTheme,
          darkTheme: zhixinDarkTheme,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            forui.FLocalizations.delegate,
          ],
          builder: (context, child) => forui.FTheme(
            data: Theme.brightnessOf(context) == Brightness.light
                ? zhixinForuiTheme
                : zhixinDarkForuiTheme,
            child: forui.FToaster(
              child: AppScope(themeMode: themeMode, child: child!),
            ),
          ),
          home: PlanPage(reader: reader),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    // 应用根就绪之后页面才装配出来，首读在它挂上树的那一帧发出。
    await tester.pump();
    expect(pending, hasLength(1));
  }

  /// 一周的数据：周二一段预约与一节固定课表，标题用来辨认是哪一周。
  PlanWeek weekData(
    DateTime weekStart, {
    required String blockTitle,
    required String timetableTitle,
  }) {
    final day = DateTime(weekStart.year, weekStart.month, weekStart.day + 1);
    return PlanWeek(
      timetable: [
        TimetableEntry(
          id: 1,
          weekday: day.weekday,
          startTime: '08:00',
          endTime: '09:00',
          title: timetableTitle,
        ),
      ],
      blocks: [
        ScheduledItem(
          block: ScheduleBlock(
            id: 1,
            planItemId: 1,
            startAt: DateTime(day.year, day.month, day.day, 10),
            endAt: DateTime(day.year, day.month, day.day, 11),
          ),
          itemTitle: blockTitle,
        ),
      ],
      items: const [],
      operations: const [],
    );
  }

  String weekTitle(DateTime weekStart) {
    final lastDay = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day + 6,
    );
    return '${weekStart.month}月${weekStart.day}日 – '
        '${lastDay.month}月${lastDay.day}日';
  }

  testWidgets('两次换周反序完成时，标题、日历、预约与课表都属于新周', (tester) async {
    final policy = TimePolicy(clock: DateTime.now);
    final thisWeek = policy.naturalWeekStart(policy.now);
    final nextWeek = DateTime(thisWeek.year, thisWeek.month, thisWeek.day + 7);
    final laterWeek = DateTime(
      thisWeek.year,
      thisWeek.month,
      thisWeek.day + 14,
    );

    await openPlanPage(tester);
    expect(pending.single.weekStart, thisWeek);

    await tester.runAsync(() async {
      complete(
        thisWeek,
        weekData(thisWeek, blockTitle: '本周的预约', timetableTitle: '本周的课'),
      );
    });
    await settle(tester);
    expect(find.text(weekTitle(thisWeek)), findsOneWidget);
    expect(find.text('本周的预约'), findsOneWidget);

    // 连点两次下一周：两次读取都还没回来。
    await tester.tap(find.bySemanticsLabel('下一周'));
    await tester.tap(find.bySemanticsLabel('下一周'));
    await settle(tester);
    expect(isWaiting(nextWeek), isTrue);
    expect(isWaiting(laterWeek), isTrue);

    // 新周先回来，旧周后回来。
    await tester.runAsync(() async {
      complete(
        laterWeek,
        weekData(laterWeek, blockTitle: '新周的预约', timetableTitle: '新周的课'),
      );
    });
    await settle(tester);
    expect(find.text(weekTitle(laterWeek)), findsOneWidget);
    expect(find.text('新周的预约'), findsOneWidget);
    expect(find.text('新周的课'), findsOneWidget);

    await tester.runAsync(() async {
      complete(
        nextWeek,
        weekData(nextWeek, blockTitle: '旧周的预约', timetableTitle: '旧周的课'),
      );
    });
    await settle(tester);

    // 旧结果不再写回：标题、预约与课表都还是新周。
    expect(find.text(weekTitle(laterWeek)), findsOneWidget);
    expect(find.text(weekTitle(nextWeek)), findsNothing);
    expect(find.text('新周的预约'), findsOneWidget);
    expect(find.text('新周的课'), findsOneWidget);
    expect(find.text('旧周的预约'), findsNothing);
    expect(find.text('旧周的课'), findsNothing);

    // 日历翻到新周，事件也只有新周的两条。
    await tester.tap(find.text('周视图'));
    await settle(tester);
    final grid = find.byType(WeekView<Object>);
    expect(tester.state<WeekViewState<Object>>(grid).currentDate, laterWeek);
    final events = tester
        .widget<WeekView<Object>>(grid)
        .controller!
        .allEvents
        .map((event) => event.title);
    expect(events, containsAll(['新周的预约', '新周的课']));
    expect(events, isNot(contains('旧周的预约')));
    expect(events, isNot(contains('旧周的课')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('刷新从当前目标周发起，结果与当前请求一致', (tester) async {
    final policy = TimePolicy(clock: DateTime.now);
    final thisWeek = policy.naturalWeekStart(policy.now);
    final nextWeek = DateTime(thisWeek.year, thisWeek.month, thisWeek.day + 7);

    await openPlanPage(tester);
    await tester.runAsync(() async {
      complete(
        thisWeek,
        weekData(thisWeek, blockTitle: '本周的预约', timetableTitle: '本周的课'),
      );
    });
    await settle(tester);

    await tester.tap(find.bySemanticsLabel('下一周'));
    await settle(tester);
    await tester.runAsync(() async {
      complete(
        nextWeek,
        weekData(nextWeek, blockTitle: '下一周的预约', timetableTitle: '下一周的课'),
      );
    });
    await settle(tester);
    expect(find.text(weekTitle(nextWeek)), findsOneWidget);

    // 数据版本变化触发刷新：重新读的是当前目标周，不是最初那一周。
    scope!.dataVersion.value++;
    await settle(tester);
    expect(lastRequestedWeek(), nextWeek);
    expect(isWaiting(nextWeek), isTrue);
    expect(isWaiting(thisWeek), isFalse);

    await tester.runAsync(() async {
      complete(
        nextWeek,
        weekData(nextWeek, blockTitle: '刷新后的预约', timetableTitle: '刷新后的课'),
      );
    });
    await settle(tester);

    expect(find.text(weekTitle(nextWeek)), findsOneWidget);
    expect(find.text('刷新后的预约'), findsOneWidget);
    expect(find.text('刷新后的课'), findsOneWidget);
    expect(find.text('下一周的预约'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
