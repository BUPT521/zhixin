import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/application/memory_view.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/ui/buddy_timeline.dart';
import 'package:zhixin/ui/theme.dart';

MemoryItemView memory({String status = 'pending', int? commitId}) {
  return MemoryItemView(
    ownerId: 1,
    itemId: 'memory-1',
    draft: MemoryDraft(
      kind: MemoryKind.preference,
      content: '讲解概率时先用具体例子。',
      source: MemorySource.inferred,
    ),
    status: status,
    commitId: commitId,
  );
}

ChatMessage message({String content = '条件概率怎么算？'}) {
  return ChatMessage(id: 1, conversationId: 1, role: 'user', content: content);
}

class FakeTimeline extends BuddyTimelineAdapter {
  FakeTimeline(
    this.entries, {
    this.scrollable = false,
    this.hasOlder = false,
    this.emptyState,
  });

  @override
  final List<BuddyTimelineEntry> entries;
  @override
  final bool scrollable;
  @override
  final bool hasOlder;
  @override
  final Widget? emptyState;

  var loaded = 0;
  var accepted = 0;
  var dismissed = 0;
  var undone = 0;

  @override
  Future<void> loadOlder() async => loaded++;

  @override
  String imagePath(String stored) => stored;

  @override
  void acceptMemory(MemoryItemView item) => accepted++;

  @override
  void dismissMemory(MemoryItemView item) => dismissed++;

  @override
  void undoMemory(MemoryItemView item) => undone++;
}

Widget wrap(Widget child, {bool scrollable = false}) {
  return MaterialApp(
    theme: zhixinTheme,
    builder: (context, child) =>
        forui.FTheme(data: zhixinForuiTheme, child: child!),
    home: Scaffold(
      // 倒序时间线自己就是滚动区，另外两条路径放在可滚动的测试宿主里。
      body: scrollable ? child : SingleChildScrollView(child: child),
    ),
  );
}

void main() {
  testWidgets('待确认的记忆卡片沿用共用的确认与忽略操作', (tester) async {
    final timeline = FakeTimeline([BuddyMemoryEntry(memory())]);
    await tester.pumpWidget(wrap(BuddyTimeline(adapter: timeline)));

    expect(find.text('记忆建议'), findsOneWidget);
    expect(find.text('待确认'), findsOneWidget);

    await tester.tap(find.text('记下'));
    expect(timeline.accepted, 1);
    await tester.tap(find.text('不记'));
    expect(timeline.dismissed, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('已记下的记忆卡片可以撤销', (tester) async {
    final timeline = FakeTimeline([
      BuddyMemoryEntry(memory(status: 'accepted', commitId: 9)),
    ]);
    await tester.pumpWidget(wrap(BuddyTimeline(adapter: timeline)));

    expect(find.text('已记下'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    expect(timeline.undone, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('失败说明与恢复入口排在记忆卡片之后', (tester) async {
    var retried = 0;
    final timeline = FakeTimeline([
      BuddyMemoryEntry(memory()),
      BuddyNoticeEntry(
        message: '模型调用失败，回答已经保存。',
        actions: [
          forui.FButton(
            variant: forui.FButtonVariant.ghost,
            mainAxisSize: MainAxisSize.min,
            onPress: () => retried++,
            child: const Text('重试这次回答'),
          ),
        ],
      ),
    ]);
    await tester.pumpWidget(wrap(BuddyTimeline(adapter: timeline)));

    expect(find.text('模型调用失败，回答已经保存。'), findsOneWidget);
    await tester.tap(find.text('重试这次回答'));
    expect(retried, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('讨论的倒序时间线在顶部给出读取较早消息', (tester) async {
    final timeline = FakeTimeline(
      [BuddyMessageEntry(message: message())],
      scrollable: true,
      hasOlder: true,
    );
    await tester.pumpWidget(
      wrap(BuddyTimeline(adapter: timeline), scrollable: true),
    );

    expect(find.text('条件概率怎么算？'), findsOneWidget);
    await tester.tap(find.text('读取较早讨论'));
    expect(timeline.loaded, 1);
    await tester.pump(const Duration(milliseconds: 150));
  });
}
