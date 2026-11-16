import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/domain/models/memory.dart';

/// 人格段落在系统提示里的固定位置与顺序说明。
void main() {
  test('人格段落排在核心规则之后、当前时间与记忆之前', () {
    final prompt = buildBuddySystemPrompt(
      BuddyContext(
        now: DateTime(2026, 11, 16, 9),
        mode: BuddyMode.chat,
        persona: const BuddyPersona(
          name: '温和讲题',
          text: '语气平和，称呼用户为“你”，先接住卡住的地方。',
        ),
        memories: const [
          Memory(
            id: 1,
            kind: MemoryKind.preference,
            content: '讲解时先给一个例子',
            status: MemoryStatus.active,
          ),
        ],
      ),
    );

    final rulesAt = prompt.indexOf('规则：');
    final personaAt = prompt.indexOf('当前启用的人格：温和讲题');
    final timeAt = prompt.indexOf('当前时间：');
    final memoryAt = prompt.indexOf('记得的事：');
    expect(rulesAt, greaterThanOrEqualTo(0));
    expect(personaAt, greaterThan(rulesAt), reason: '人格段落排在核心规则之后');
    expect(timeAt, greaterThan(personaAt), reason: '人格段落排在当前时间之前');
    expect(memoryAt, greaterThan(timeAt), reason: '人格段落排在记忆之前');
    expect(prompt, contains('语气平和，称呼用户为“你”，先接住卡住的地方。'));
    expect(prompt, contains('讲解时先给一个例子'));
  });

  test('启用人格时补一条规则说明顺序与边界', () {
    final prompt = buildBuddySystemPrompt(
      BuddyContext(
        now: DateTime(2026, 11, 16, 9),
        mode: BuddyMode.hint,
        persona: const BuddyPersona(name: '简短直接', text: '篇幅偏短。'),
      ),
    );
    expect(prompt, contains('人格只影响语气、称呼、讲解风格与篇幅倾向'));
    expect(prompt, contains('不改变判分、引用、写入、工具使用与事实依据'));
    expect(prompt, contains('用户本轮说明优先于人格'));
    expect(prompt, contains('人格优先于记忆里的讲解偏好'));
    expect(prompt, contains('记忆里的困难、进展与时间限制照常带入'));
  });

  test('没有启用人格时不出现人格段落与人格规则', () {
    final prompt = buildBuddySystemPrompt(
      BuddyContext(now: DateTime(2026, 11, 16, 9), mode: BuddyMode.chat),
    );
    expect(prompt, isNot(contains('当前启用的人格')));
    expect(prompt, isNot(contains('人格只影响')));
    expect(prompt, contains('当前时间：'));
    expect(prompt, contains('记得的事：'));
  });

  test('人格文本超过上限时按码位兜底截断，不把长文本整段塞进提示词', () {
    final prompt = buildBuddySystemPrompt(
      BuddyContext(
        now: DateTime(2026, 11, 16, 9),
        mode: BuddyMode.chat,
        persona: BuddyPersona(name: '过长', text: '甲' * 900),
      ),
    );
    expect(prompt, contains('${'甲' * 800}…'));
    expect(prompt.contains('甲' * 801), isFalse);
  });

  test('人格段落不随请求类型改变，检查与讲解同样带在固定位置', () {
    for (final mode in BuddyMode.values) {
      final prompt = buildBuddySystemPrompt(
        BuddyContext(
          now: DateTime(2026, 11, 16, 9),
          mode: mode,
          persona: const BuddyPersona(name: '温和讲题', text: '慢慢讲。'),
        ),
      );
      expect(
        prompt.indexOf('当前启用的人格：温和讲题'),
        greaterThan(prompt.indexOf('规则：')),
        reason: '$mode 的人格段落仍在规则之后',
      );
      expect(
        prompt.indexOf('当前时间：'),
        greaterThan(prompt.indexOf('当前启用的人格：温和讲题')),
      );
    }
  });
}
