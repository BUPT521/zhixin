import 'dart:async';
import 'dart:io';

import 'package:calendar_view/calendar_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/ui/plan_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

/// 安排页的换周订阅：换周只保留最新一条订阅，迟到的旧周数据不再写回；
/// 写入之后的新数据由订阅带回，下拉刷新重新订阅当前目标周。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

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
    await scope?.testing.db.close();
    scope = null;
    await directory.delete(recursive: true);
  });

  /// 页面订阅过的周，按请求顺序；同一周重新订阅会再记一次。
  late List<DateTime> requested;

  /// 每个周一对应最近一次订阅的流；用例按自己的顺序把数据交回去。
  late Map<DateTime, StreamController<PlanWeek>> streams;

  setUp(() {
    requested = [];
    streams = {};
  });

  /// 安排页注入的读法：每个目标周给一条流，数据什么时候回来由用例决定。
  Stream<PlanWeek> watchWeek(DateTime weekStart) {
    requested.add(weekStart);
    final controller = StreamController<PlanWeek>();
    streams[weekStart] = controller;
    return controller.stream;
  }

  /// 订阅带回一份数据，相当于一次读取完成，或一次写入之后的重读。
  void emit(DateTime weekStart, PlanWeek week) {
    streams[weekStart]!.add(week);
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
          home: PlanPage(watchWeek: watchWeek),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    // 应用根就绪之后页面才装配出来，首读的订阅在它挂上树的那一帧建立。
    await tester.pump();
    expect(requested, hasLength(1));
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
          id: 'entry-1',
          weekday: day.weekday,
          startTime: '08:00',
          endTime: '09:00',
          title: timetableTitle,
        ),
      ],
      blocks: [
        ScheduledItem(
          block: ScheduleBlock(
            id: 'block-1',
            planItemId: 'item-1',
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

  testWidgets('换周只保留最新一条订阅，迟到的旧周数据不再写回', (tester) async {
    final policy = TimePolicy(clock: DateTime.now);
    final thisWeek = policy.naturalWeekStart(policy.now);
    final nextWeek = DateTime(thisWeek.year, thisWeek.month, thisWeek.day + 7);
    final laterWeek = DateTime(
      thisWeek.year,
      thisWeek.month,
      thisWeek.day + 14,
    );

    await openPlanPage(tester);
    expect(requested, [thisWeek]);

    emit(
      thisWeek,
      weekData(thisWeek, blockTitle: '本周的预约', timetableTitle: '本周的课'),
    );
    await settle(tester);
    expect(find.text(weekTitle(thisWeek)), findsOneWidget);
    expect(find.text('本周的预约'), findsOneWidget);

    // 连点两次下一周：两个新周各换一条订阅，最初那条已经退订。
    await tester.tap(find.bySemanticsLabel('下一周'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('下一周'));
    await settle(tester);
    expect(requested, [thisWeek, nextWeek, laterWeek]);

    emit(
      laterWeek,
      weekData(laterWeek, blockTitle: '新周的预约', timetableTitle: '新周的课'),
    );
    await settle(tester);
    expect(find.text(weekTitle(laterWeek)), findsOneWidget);
    expect(find.text('新周的预约'), findsOneWidget);
    expect(find.text('新周的课'), findsOneWidget);

    // 旧周的读取在退订之后才回来，不再写回标题、预约与课表。
    emit(
      nextWeek,
      weekData(nextWeek, blockTitle: '旧周的预约', timetableTitle: '旧周的课'),
    );
    await settle(tester);

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

  testWidgets('写入之后订阅带回的新数据直接显示，页面不重新订阅', (tester) async {
    final policy = TimePolicy(clock: DateTime.now);
    final thisWeek = policy.naturalWeekStart(policy.now);

    await openPlanPage(tester);
    emit(
      thisWeek,
      weekData(thisWeek, blockTitle: '写入前的预约', timetableTitle: '写入前的课'),
    );
    await settle(tester);
    expect(find.text('写入前的预约'), findsOneWidget);
    expect(find.text('写入前的课'), findsOneWidget);

    // 写入提交之后，数据层在同一条订阅上再回填一次；页面不再自己重读。
    emit(
      thisWeek,
      weekData(thisWeek, blockTitle: '写入后的预约', timetableTitle: '写入后的课'),
    );
    await settle(tester);

    expect(requested, [thisWeek]);
    expect(find.text(weekTitle(thisWeek)), findsOneWidget);
    expect(find.text('写入后的预约'), findsOneWidget);
    expect(find.text('写入后的课'), findsOneWidget);
    expect(find.text('写入前的预约'), findsNothing);
    expect(find.text('写入前的课'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉刷新重新订阅当前目标周，不回到最初那一周', (tester) async {
    final policy = TimePolicy(clock: DateTime.now);
    final thisWeek = policy.naturalWeekStart(policy.now);
    final nextWeek = DateTime(thisWeek.year, thisWeek.month, thisWeek.day + 7);

    await openPlanPage(tester);
    emit(
      thisWeek,
      weekData(thisWeek, blockTitle: '本周的预约', timetableTitle: '本周的课'),
    );
    await settle(tester);

    await tester.tap(find.bySemanticsLabel('下一周'));
    await settle(tester);
    emit(
      nextWeek,
      weekData(nextWeek, blockTitle: '下一周的预约', timetableTitle: '下一周的课'),
    );
    await settle(tester);
    expect(find.text(weekTitle(nextWeek)), findsOneWidget);

    // 下拉刷新只重新订阅当前目标周，最初那一周不再重读。
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator).first)
        .onRefresh;
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = refresh();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(requested.last, nextWeek);
    expect(requested.where((week) => week == thisWeek), hasLength(1));

    emit(
      nextWeek,
      weekData(nextWeek, blockTitle: '刷新后的预约', timetableTitle: '刷新后的课'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => pending);
    await settle(tester);

    expect(find.text(weekTitle(nextWeek)), findsOneWidget);
    expect(find.text('刷新后的预约'), findsOneWidget);
    expect(find.text('刷新后的课'), findsOneWidget);
    expect(find.text('下一周的预约'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
