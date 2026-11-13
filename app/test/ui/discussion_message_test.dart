import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/ui/discussion_message.dart';
import 'package:zhixin/ui/markdown_text.dart';
import 'package:zhixin/ui/theme.dart';

void main() {
  Widget app(Widget body) => MaterialApp(
    theme: zhixinTheme,
    // 卡片、进度与展开区都来自 Forui，需要上层提供 FTheme 与无障碍作用域。
    builder: (context, child) =>
        forui.FTheme(data: zhixinForuiTheme, child: child!),
    home: Scaffold(body: body),
  );

  testWidgets('流式回答先显示等待，收到正文后直接显示', (tester) async {
    await tester.pumpWidget(app(const StreamingMessage(text: '')));
    expect(find.text('正在回答'), findsOneWidget);

    await tester.pumpWidget(app(const StreamingMessage(text: '先看定义，再回到这一步。')));
    expect(
      find.textContaining('先看定义，再回到这一步。', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('正在回答'), findsNothing);
  });

  testWidgets('回答按 Markdown 渲染，不把星号显示出来', (tester) async {
    await tester.pumpWidget(
      app(const StreamingMessage(text: '**先看定义**，再看例题。')),
    );
    expect(find.textContaining('先看定义', findRichText: true), findsOneWidget);
    expect(find.textContaining('**', findRichText: true), findsNothing);
  });

  testWidgets('完成后的回答也按 Markdown 渲染', (tester) async {
    await tester.pumpWidget(
      app(
        DiscussionMessage(
          message: const ChatMessage(
            id: 1,
            conversationId: 1,
            role: 'assistant',
            content: '## 看条件\n\n**重点**是 `P(B) > 0`。',
          ),
          imagePath: (path) => path,
        ),
      ),
    );

    expect(find.textContaining('看条件', findRichText: true), findsWidgets);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('##', findRichText: true), findsNothing);
  });

  testWidgets('窄屏里带代码块与表格的回答不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const content = '''
## 小标题

先看 **定义**，再看 `示例`。

| 条件 | 概率 | 说明 |
|---|---|---|
| A 发生 | 0.5 | 第一次试验 |
| B 发生 | 0.3 | 第二次试验 |

```dart
final value = computeSomethingVeryLong(alpha, beta, gamma, delta);
```
''';

    await tester.pumpWidget(
      app(const SingleChildScrollView(child: StreamingMessage(text: content))),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('先看', findRichText: true), findsOneWidget);
  });

  testWidgets('生成中的回答末尾显示三点提示，完成后不再显示', (tester) async {
    await tester.pumpWidget(app(const StreamingMessage(text: '先看定义，再回到这一步。')));
    expect(find.byType(StreamingHint), findsOneWidget);

    await tester.pumpWidget(
      app(
        DiscussionMessage(
          message: const ChatMessage(
            id: 1,
            conversationId: 1,
            role: 'assistant',
            content: '先看定义，再回到这一步。',
          ),
          imagePath: (path) => path,
        ),
      ),
    );
    expect(find.byType(StreamingHint), findsNothing);
  });

  testWidgets('美元符号包裹的内容按公式渲染，不显示美元符号', (tester) async {
    await tester.pumpWidget(
      app(const StreamingMessage(text: r'面积是 $x^2$ 平方。')),
    );
    expect(find.textContaining(r'$', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用显示核对状态，展开后可以选中完整引文', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      app(
        SingleChildScrollView(
          child: DiscussionMessage(
            message: const ChatMessage(
              id: 1,
              conversationId: 1,
              role: 'assistant',
              content: '下面两条材料的核对结果不同。',
              structuredJson: '''
{
  "citations": [
    {"material_id": 1, "material_title": "概率论", "page_no": 7,
     "quote": "概率只在所给事件中重新计算。", "verified": true},
    {"material_id": 2, "material_title": "习题", "page_no": 9,
     "quote": "还未核对的引文。", "verified": false}
  ]
}
''',
            ),
            imagePath: (path) => path,
          ),
        ),
      ),
    );

    expect(find.text('已核对'), findsOneWidget);
    expect(find.text('未能核对'), findsOneWidget);
    final quote = find.text('概率只在所给事件中重新计算。');
    // Forui 的分组即使收起也会把内容留在控件树里，只是裁掉；这里按能否点击判断可见性。
    expect(quote.hitTestable(), findsNothing);

    await tester.tap(find.text('《概率论》 第 7 页'));
    await tester.pumpAndSettle();
    expect(quote.hitTestable(), findsOneWidget);
    expect(
      find.ancestor(of: quote, matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地回答在卡片内标明来源', (tester) async {
    await tester.pumpWidget(
      app(
        DiscussionMessage(
          message: const ChatMessage(
            id: 1,
            conversationId: 1,
            role: 'assistant',
            content: '先记录一道题。',
            structuredJson: '{"model":false}',
          ),
          imagePath: (path) => path,
        ),
      ),
    );

    expect(find.widgetWithText(DiscussionCard, '本地规则'), findsOneWidget);
  });

  testWidgets('停止生成的回答带标记，重新打开也能看出没写完', (tester) async {
    await tester.pumpWidget(
      app(
        DiscussionMessage(
          message: const ChatMessage(
            id: 1,
            conversationId: 1,
            role: 'assistant',
            content: '先看定义',
            structuredJson: '{"model":false,"stopped":true}',
          ),
          imagePath: (path) => path,
        ),
      ),
    );

    expect(find.textContaining('先看定义', findRichText: true), findsOneWidget);
    expect(find.text('已停止生成'), findsOneWidget);
    expect(find.text('本地规则'), findsNothing);
  });

  testWidgets('生成中断的回答带标记，重新打开也能看出没写完', (tester) async {
    await tester.pumpWidget(
      app(
        DiscussionMessage(
          message: const ChatMessage(
            id: 1,
            conversationId: 1,
            role: 'assistant',
            content: '先看定义',
            structuredJson: '{"model":true,"interrupted":true}',
          ),
          imagePath: (path) => path,
        ),
      ),
    );

    expect(find.textContaining('先看定义', findRichText: true), findsOneWidget);
    expect(find.text('生成中断'), findsOneWidget);
    expect(find.text('已停止生成'), findsNothing);
  });
}
