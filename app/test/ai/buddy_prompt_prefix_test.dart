import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/domain/models/memory.dart';

/// 稳定前缀与后段的划分：同一讨论里每次请求都相同的内容必须落在当前时间之前，
/// 上游才能复用这段前缀的缓存（方案第 5 节）。
void main() {
  BuddyContext contextAt(DateTime now) => BuddyContext(
    now: now,
    mode: BuddyMode.chat,
    memories: const [
      Memory(
        id: 'memory-1',
        kind: MemoryKind.semantic,
        content: '讲解时先给一个例子',
        status: MemoryStatus.active,
      ),
    ],
  );

  String prefixOf(String prompt) =>
      prompt.substring(0, prompt.indexOf('当前时间：'));

  test('当前时间之前的内容不随这一轮的时间变化', () {
    final first = buildBuddySystemPrompt(contextAt(DateTime(2026, 11, 16, 9)));
    final second = buildBuddySystemPrompt(
      contextAt(DateTime(2026, 11, 16, 21, 30)),
    );
    expect(first, isNot(equals(second)));
    expect(prefixOf(first), prefixOf(second));
    expect(prefixOf(first), contains('规则：'));
    expect(prefixOf(first), contains('本次讨论归属：'));
  });

  test('时间、记忆与其余随请求变化的内容排在前缀之后', () {
    final prompt = buildBuddySystemPrompt(contextAt(DateTime(2026, 11, 16, 9)));
    final timeAt = prompt.indexOf('当前时间：');
    expect(timeAt, greaterThan(prompt.indexOf('规则：')));
    expect(prompt.indexOf('记得的事（[情景]'), greaterThan(timeAt));
  });
}
