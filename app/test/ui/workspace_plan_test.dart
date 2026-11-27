import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/workspace_widgets.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('事项可定位来源讨论与材料原文', (tester) async {
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
    await tester.tap(find.text('返回来源讨论'));
    await settle(tester);
    expect(
      tester.widget<DiscussionPage>(find.byType(DiscussionPage)).conversationId,
      data!.conversation,
    );
    await tester.tap(discussionMoreMenu());
    await settle(tester);
    await tester.tap(find.text('查看原文'));
    await settle(tester);
    expect(find.text('导数描述函数在一点附近的变化率。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切页签时旧页签整幅滑出，新页签从屏幕右边缘进来', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('事项'));
    await settle(tester);

    Finder layer(int tab) =>
        find.byKey(ValueKey('plan-tab-layer-$tab'), skipOffstage: false);
    Finder inLayer(int tab, String text) => find.descendant(
      of: layer(tab),
      matching: find.text(text, skipOffstage: false),
      skipOffstage: false,
    );

    // 屏宽 390，页面边距 24：新页从屏幕右边缘之外开始，不是从版心右边界开始。
    await tester.tap(find.text('目标'));
    await tester.pump();
    expect(
      tester.getTopLeft(inLayer(1, '学习目标')).dx,
      moreOrLessEquals(390 + 24, epsilon: 0.5),
    );

    // 动画走完之前旧页已经整幅滑到屏幕左边缘之外，右端的“新建”不再停在边距里。
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getTopRight(inLayer(0, '新建')).dx, lessThanOrEqualTo(0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(inLayer(1, '学习目标')).dx, moreOrLessEquals(24));
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
