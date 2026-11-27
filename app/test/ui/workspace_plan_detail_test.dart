import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/ui/plan_page.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

import 'workspace_support.dart';

/// 从首页或查找结果打开事项详情：查不到与读失败要分开，后者不能静默（A9）。
void main() {
  registerWorkspaceTests();

  const empty = PlanOverview(items: []);

  /// 直接推入详情页，换掉按编号补读的读法，模拟“查不到”与“读失败”。
  Future<void> pushDetail(
    WidgetTester tester, {
    required String itemId,
    required Future<PlanItem?> Function(String id) itemById,
  }) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PlanPage.detail(
          itemId: itemId,
          watchOverview: () => Stream<PlanOverview>.value(empty),
          itemById: itemById,
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('查不到这条事项时不打开操作面板，也不报错', (tester) async {
    await openApp(tester);
    await pushDetail(tester, itemId: '已删除的事项', itemById: (_) async => null);

    // 详情页照常显示安排的内容，没有弹出“完成事项”之类的操作面板。
    expect(find.text('完成事项'), findsNothing);
    expect(find.text('标记进行中'), findsNothing);
    expect(find.byType(InlineNotice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('补读事项失败时在详情页就地说明并给出重试', (tester) async {
    await openApp(tester);
    await pushDetail(
      tester,
      itemId: '读不到的事项',
      itemById: (_) async => throw StateError('测试里的读取失败'),
    );

    expect(find.byType(InlineNotice), findsOneWidget);
    expect(find.textContaining('读取事项详情没有完成'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
