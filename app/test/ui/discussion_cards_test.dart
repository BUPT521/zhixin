import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/application/buddy_actions.dart';
import 'package:zhixin/application/discussion_service.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/ui/discussion_cards.dart';

MemoryItemView memory({
  String content = '讲解概率时先用具体例子。',
  MemoryKind kind = MemoryKind.preference,
  MemorySource source = MemorySource.inferred,
  DateTime? validUntil,
  String status = 'pending',
  int? commitId,
}) {
  return MemoryItemView(
    messageId: 1,
    itemId: 'memory-1',
    draft: MemoryDraft(
      kind: kind,
      content: content,
      source: source,
      validUntil: validUntil,
    ),
    status: status,
    commitId: commitId,
  );
}

PendingSuggestion suggestion({
  String title = '用抽球问题练习条件概率',
  String? action = '分别写出已知条件与要求的事件。',
  String? endCondition = '能独立写对两题。',
  int? minutes,
}) {
  return PendingSuggestion(
    messageId: 2,
    stepId: 's1',
    draft: NextStepDraft(
      title: title,
      action: action,
      endCondition: endCondition,
      minutes: minutes,
    ),
  );
}

Widget wrap(Widget child) {
  return MaterialApp(
    theme: zhixinTheme,
    // 按钮已换成 Forui 的 FButton，它要求上层有 FTheme。
    builder: (context, child) =>
        forui.FTheme(data: zhixinForuiTheme, child: child!),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('待确认的记忆写明类型、来源与有效期，确认与忽略分别回调', (tester) async {
    var accepted = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      wrap(
        MemoryCard(
          item: memory(validUntil: DateTime(2026, 12, 31)),
          onAccept: () => accepted++,
          onDismiss: () => dismissed++,
          onUndo: () {},
        ),
      ),
    );

    expect(find.text('记忆建议'), findsOneWidget);
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('讲解概率时先用具体例子。'), findsOneWidget);
    expect(find.text('偏好 · 模型推断 · 有效至 2026-12-31'), findsOneWidget);
    expect(find.text('撤销'), findsNothing);

    await tester.tap(find.text('记下'));
    expect(accepted, 1);
    expect(dismissed, 0);

    await tester.tap(find.text('不记'));
    expect(dismissed, 1);
    expect(accepted, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('用户明说的记忆不写期限，已写入的记忆只保留撤销', (tester) async {
    var undone = 0;
    await tester.pumpWidget(
      wrap(
        MemoryCard(
          item: memory(
            source: MemorySource.user,
            status: 'accepted',
            commitId: 9,
          ),
          onAccept: () {},
          onDismiss: () {},
          onUndo: () => undone++,
        ),
      ),
    );

    expect(find.text('已记下'), findsOneWidget);
    expect(find.text('待确认'), findsNothing);
    expect(find.text('偏好 · 你说的 · 长期有效'), findsOneWidget);
    expect(find.text('记下'), findsNothing);
    expect(find.text('不记'), findsNothing);

    await tester.tap(find.text('撤销'));
    expect(undone, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('没有操作编号的已写入记忆不能撤销', (tester) async {
    await tester.pumpWidget(
      wrap(
        MemoryCard(
          item: memory(status: 'accepted'),
          onAccept: () {},
          onDismiss: () {},
          onUndo: () {},
        ),
      ),
    );

    final undo = tester.widget<forui.FButton>(
      find.widgetWithText(forui.FButton, '撤销'),
    );
    expect(undo.onPress, isNull);
  });

  testWidgets('建议卡显示要做的事、结束条件与时长，三个操作各自回调', (tester) async {
    var accepted = 0;
    var scheduled = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      wrap(
        SuggestionCard(
          suggestion: suggestion(minutes: 10),
          onAccept: () => accepted++,
          onSchedule: () => scheduled++,
          onDismiss: () => dismissed++,
        ),
      ),
    );

    expect(find.text('下一步建议'), findsOneWidget);
    expect(find.text('约 10 分钟'), findsOneWidget);
    expect(find.text('用抽球问题练习条件概率'), findsOneWidget);
    expect(find.text('要做的事：分别写出已知条件与要求的事件。'), findsOneWidget);
    expect(find.text('结束条件：能独立写对两题。'), findsOneWidget);

    await tester.tap(find.text('保存为学习事项'));
    expect(accepted, 1);
    await tester.tap(find.text('保存并选时间'));
    expect(scheduled, 1);
    await tester.tap(find.text('暂不安排'));
    expect(dismissed, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('没有时长与说明的建议不显示多余的标签', (tester) async {
    await tester.pumpWidget(
      wrap(
        SuggestionCard(
          suggestion: suggestion(action: null, endCondition: null),
          onAccept: () {},
          onSchedule: () {},
          onDismiss: () {},
        ),
      ),
    );

    expect(find.text('用抽球问题练习条件概率'), findsOneWidget);
    expect(find.textContaining('分钟'), findsNothing);
    expect(find.textContaining('要做的事'), findsNothing);
    expect(find.textContaining('结束条件'), findsNothing);
  });

  testWidgets('回执按条列出改动，撤销带出对应那一条', (tester) async {
    final undone = <AppliedChange>[];
    const changes = [
      AppliedChange(commitId: 3, text: '已添加记忆：偏好 · 讲解先用例子'),
      AppliedChange(commitId: 4, text: '已创建学习事项：练习条件概率'),
    ];
    await tester.pumpWidget(
      wrap(ChangeReceiptCard(changes: changes, onUndo: undone.add)),
    );

    expect(find.text('改动回执'), findsOneWidget);
    expect(find.text('已添加记忆：偏好 · 讲解先用例子'), findsOneWidget);
    expect(find.text('已创建学习事项：练习条件概率'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('撤销'), findsNWidgets(2));

    await tester.tap(find.text('撤销').at(1));
    expect(undone, [changes[1]]);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('窄屏与放大文字下记忆卡不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      wrap(
        MemoryCard(
          item: memory(
            content: '讲解概率时先用具体例子，再回到公式，最后才做需要两步推理的题目。',
            kind: MemoryKind.difficulty,
            validUntil: DateTime(2026, 12, 31),
          ),
          onAccept: () {},
          onDismiss: () {},
          onUndo: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('记忆建议'), findsOneWidget);
  });
}
