import 'package:calendar_view/calendar_view.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/time_values.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/format.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/workspace_widgets.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('事项可定位来源讨论与材料原文，预约预选对应事项', (tester) async {
    await openApp(tester);
    final data = await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '微积分讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数描述函数在一点附近的变化率。',
      );
      final conversation = await scope!.chat.discussion.createConversation(
        title: '理解变化率',
        materialId: material,
        pageNo: 3,
      );
      final item = await scope!.testing.tasks.createItem(
        title: '练习导数定义',
        conversationId: conversation,
        note: '阅读第 3 页后独立写出定义，解释差商与极限的关系',
        estMinutes: 20,
      );
      await scope!.testing.tasks.createItem(title: '另一项任务');
      return (conversation: conversation, item: item);
    });
    await tester.tap(find.text('安排').last);
    await settle(tester);
    await preview(tester, 'plan');
    await tester.tap(find.text('事项'));
    await settle(tester);
    await tester.tap(find.text('练习导数定义'));
    await settle(tester);
    await preview(tester, 'item-detail');
    await tester.tap(find.text('预约时间').last);
    await settle(tester);
    final dropdown = tester.widget<forui.FSelect<String>>(
      select<String>('学习事项'),
    );
    final selected = tester.widget<EditableText>(selectField<String>('学习事项'));
    expect(dropdown.format(data!.item), '练习导数定义');
    expect(selected.controller.text, '练习导数定义');
    await tester.tap(find.text('取消').last);
    await settle(tester);
    await tester.tap(find.text('练习导数定义'));
    await settle(tester);
    await tester.tap(find.text('返回来源讨论'));
    await settle(tester);
    expect(
      tester.widget<DiscussionPage>(find.byType(DiscussionPage)).conversationId,
      data.conversation,
    );
    await tester.tap(discussionMoreMenu());
    await settle(tester);
    await tester.tap(find.text('查看原文'));
    await settle(tester);
    expect(find.text('导数描述函数在一点附近的变化率。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成事项滚动时自动续读，切回事项页签时保留滚动位置', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      for (var i = 0; i < 32; i++) {
        final id = await scope!.testing.tasks.createItem(title: '已完成事项 $i');
        await scope!.study.plan.setStatus(id, PlanItemStatus.done);
      }
    });

    await tester.tap(find.text('安排').last);
    await settle(tester);
    await tester.tap(find.text('事项'));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const PageStorageKey<String>('plan-tab-1')),
          matching: find.byType(Scrollable),
        )
        .first;
    final toggle = find.text('显示已完成（32）');
    await tester.tap(toggle);
    await settle(tester);
    expect(find.text('已完成事项 31'), findsOneWidget);
    expect(find.text('已完成事项 2'), findsNothing);
    expect(find.byType(LoadMoreFooter), findsNothing);

    await tester.scrollUntilVisible(
      find.text('已完成事项 2'),
      350,
      scrollable: scrollable,
    );
    await settle(tester);
    await tester.drag(scrollable, const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.text('已完成事项 0').hitTestable(), findsOneWidget);
    expect(find.text('已完成事项 1').hitTestable(), findsOneWidget);
    expect(find.byType(LoadMoreFooter), findsNothing);

    final offset = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset, greaterThan(0));
    await tester.tap(find.text('目标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事项'));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, offset);
    expect(find.text('已完成事项 0').hitTestable(), findsOneWidget);

    final collapse = find.text('收起已完成');
    await tester.scrollUntilVisible(collapse, -350, scrollable: scrollable);
    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(toggle, findsOneWidget);
    expect(find.text('已完成事项 31'), findsNothing);
  });

  testWidgets('展开的周视图与周切换按钮显示同一周', (tester) async {
    await openApp(tester, size: const Size(390, 1100));
    await tester.runAsync(
      () => scope!.study.plan.addTimetable(
        weekday: 3,
        startTime: '08:00',
        endTime: '09:00',
        title: '数据结构',
      ),
    );
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('周视图'));
    await settle(tester);

    final grid = find.byType(WeekView<Object>);
    WeekViewState<Object> calendar() =>
        tester.state<WeekViewState<Object>>(grid);

    final firstWeek = calendar().currentDate;
    final nextWeek = find.bySemanticsLabel('下一周');
    await tester.tap(nextWeek);
    await tester.tap(nextWeek);
    await settle(tester);
    final selectedWeek = DateTime(
      firstWeek.year,
      firstWeek.month,
      firstWeek.day + 14,
    );
    expect(calendar().currentDate, selectedWeek);

    await tester.fling(grid, const Offset(300, 0), 900);
    await settle(tester);
    final previousWeek = DateTime(
      firstWeek.year,
      firstWeek.month,
      firstWeek.day + 7,
    );
    expect(calendar().currentDate, previousWeek);
    expect(
      find.textContaining('${previousWeek.month}月${previousWeek.day}日 – '),
      findsOneWidget,
    );
    final event = tester
        .widget<WeekView<Object>>(grid)
        .controller!
        .allEvents
        .single;
    expect(
      event.date,
      DateTime(previousWeek.year, previousWeek.month, previousWeek.day + 2),
    );

    await tester.tap(find.text('回到本周'));
    await settle(tester);
    expect(calendar().currentDate, firstWeek);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表可以删除', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.study.plan.addTimetable(
        weekday: 3,
        startTime: '08:00',
        endTime: '09:00',
        title: '数据结构',
      ),
    );
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.scrollUntilVisible(
      find.byIcon(FLucideIcons.trash2),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // 底部导航栏盖住列表末端，再往上拖一段，删除按钮才落在可点击的区域内。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.trash2));
    await settle(tester);
    expect(find.text('删除这节课'), findsOneWidget);
    await tester.tap(find.widgetWithText(forui.FButton, '删除'));
    await settle(tester);

    expect(find.text('数据结构'), findsNothing);
    expect(
      await tester.runAsync(() => scope!.testing.schedule.timetable()),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间预算沿用已保存的可用时段', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.study.capacity.setWindow(
        start: ClockTime.parse('19:00'),
        end: ClockTime.parse('19:30'),
      ),
    );
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);
    expect(find.text('常用学习时段：19:00–19:30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间预算点选算出的空档直接预约', (tester) async {
    await openApp(tester, clock: () => DateTime(2026, 11, 16, 9));
    final itemId = await tester.runAsync(() async {
      await scope!.study.capacity.setWindow(
        start: ClockTime.parse('19:00'),
        end: ClockTime.parse('19:30'),
      );
      return scope!.testing.tasks.createItem(title: '整理笔记', estMinutes: 20);
    });
    final window = await tester.runAsync(() async {
      final plan = await scope!.study.capacity.compute();
      return plan.candidates.single.windows.first;
    });
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);

    final label =
        '${dayLabel(window!.start)} '
        '${clockOf(window.start)}–${clockOf(window.end)}';
    expect(find.text(label), findsOneWidget);
    await tester.tap(find.text(label).hitTestable());
    await settle(tester);

    // 写入之前先说明这次会新建预约到什么时间。
    expect(find.text('按这个空档预约'), findsOneWidget);
    expect(find.textContaining('新建预约：'), findsOneWidget);
    expect(find.textContaining('这次只调整这一项'), findsOneWidget);
    await tester.tap(find.text('按这个时间预约'));
    await settle(tester);

    final blocks = await tester.runAsync(
      () => scope!.testing.schedule.blocksForItem(itemId!),
    );
    expect(blocks, hasLength(1));
    expect(blocks!.single.startAt, window.start);
    expect(blocks.single.endAt, window.end);
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间预算点选空档前说明原预约会改到的时间', (tester) async {
    await openApp(tester, clock: () => DateTime(2026, 11, 16, 9));
    final itemId = await tester.runAsync(() async {
      await scope!.study.capacity.setWindow(
        start: ClockTime.parse('19:00'),
        end: ClockTime.parse('19:30'),
      );
      final id = await scope!.testing.tasks.createItem(
        title: '整理笔记',
        estMinutes: 20,
      );
      final day = DateTime(2026, 11, 17);
      await scope!.testing.schedule.addBlock(
        planItemId: id,
        start: DateTime(day.year, day.month, day.day, 18),
        end: DateTime(day.year, day.month, day.day, 18, 20),
      );
      return id;
    });
    final window = await tester.runAsync(() async {
      final plan = await scope!.study.capacity.compute();
      return plan.candidates.single.windows.first;
    });
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);

    expect(find.text('这次估算会把以下弹性预约算作可调整'), findsOneWidget);
    expect(find.text('没有点选的预约保持原时间。'), findsOneWidget);

    final label =
        '${dayLabel(window!.start)} '
        '${clockOf(window.start)}–${clockOf(window.end)}';
    await tester.tap(find.text(label).hitTestable());
    await settle(tester);

    expect(find.textContaining('原预约：'), findsOneWidget);
    expect(find.textContaining('改到：'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);

    final blocks = await tester.runAsync(
      () => scope!.testing.schedule.blocksForItem(itemId!),
    );
    expect(blocks, hasLength(1));
    expect(blocks!.single.startAt.hour, 18);
    expect(blocks.single.endAt.hour, 18);

    // 再选一次，保留原预约并追加一段。
    await tester.tap(find.text(label).hitTestable());
    await settle(tester);
    expect(find.text('再加一段'), findsOneWidget);
    await tester.tap(find.text('再加一段'));
    await settle(tester);
    final two = await tester.runAsync(
      () => scope!.testing.schedule.blocksForItem(itemId!),
    );
    expect(two, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统学习设置框在真机宽度下不溢出', (tester) async {
    await openApp(tester, size: const Size(363, 792));
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '概率论讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '条件概率的定义。',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 2,
        content: '全概率公式。',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
    await tester.tap(find.text('概率论讲义'));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.route));
    await settle(tester);
    expect(find.textContaining('系统学习《概率论讲义》'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统学习确认前标明顺序来源', (tester) async {
    await openApp(tester, size: const Size(390, 844));
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '概率论讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '条件概率的定义。',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 2,
        content: '全概率公式。',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
    await tester.tap(find.text('概率论讲义'));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.route));
    await settle(tester);
    await tester.tap(find.text('生成顺序'));
    await settle(tester);
    expect(find.textContaining('来源：按页顺序'), findsOneWidget);
    expect(find.textContaining('覆盖本次所选 2 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
