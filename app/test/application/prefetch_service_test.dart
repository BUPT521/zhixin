import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/prefetch_service.dart';

void main() {
  late DateTime now;

  setUp(() => now = DateTime(2026, 11, 19, 10));

  PrefetchService build({
    Map<PrefetchArea, List<Future<void> Function()>> tasks = const {},
  }) => PrefetchService(clock: () => now, tasks: tasks);

  test('同一个键在有效期内只读一次，后来者拿到同一份结果', () async {
    final service = build();
    var reads = 0;
    final first = service.warm(PrefetchKey.memory, () async {
      reads++;
      return '第一份';
    });
    final second = service.warm(PrefetchKey.memory, () async {
      reads++;
      return '第二份';
    });

    expect(await first, '第一份');
    expect(await second, '第一份');
    expect(reads, 1);
    expect(service.peek<String>(PrefetchKey.memory), '第一份');
  });

  test('取走之后不再命中，之后再读重新取一份', () async {
    final service = build();
    await service.warm(PrefetchKey.settings, () async => 42);

    expect(service.peek<int>(PrefetchKey.settings), 42);
    expect(service.peek<int>(PrefetchKey.settings), 42);
    expect(service.take<int>(PrefetchKey.settings), 42);
    expect(service.peek<int>(PrefetchKey.settings), isNull);
  });

  test('一级界面读到的结果可以留给二级界面，warm 不会复用没有读取的项', () async {
    final service = build();
    service.put<String>(PrefetchKey.accountPage, '账号与额度');

    expect(service.peek<String>(PrefetchKey.accountPage), '账号与额度');
    expect(
      await service.warm(PrefetchKey.accountPage, () async => '重新读取'),
      '重新读取',
    );
    expect(service.peek<String>(PrefetchKey.accountPage), '重新读取');
  });

  test('读取失败时移除这一项，页面可以自己再读一次', () async {
    final service = build();
    await expectLater(
      service.warm<String>(
        PrefetchKey.memory,
        () => Future<String>.error(StateError('读取失败')),
      ),
      throwsStateError,
    );

    expect(service.peek<String>(PrefetchKey.memory), isNull);
    expect(await service.warm(PrefetchKey.memory, () async => '再来一次'), '再来一次');
  });

  test('读取同步抛出时也不留下半项', () async {
    final service = build();
    final pending = service.warm<String>(
      PrefetchKey.memory,
      () => throw StateError('同步失败'),
    );

    await expectLater(pending, throwsStateError);
    expect(service.peek<String>(PrefetchKey.memory), isNull);
  });

  test('超过有效期之后不再命中', () async {
    final service = build();
    await service.warm(PrefetchKey.dataVersion, () async => '旧一屏');

    now = now.add(const Duration(minutes: 4));
    expect(service.peek<String>(PrefetchKey.dataVersion), '旧一屏');

    now = now.add(const Duration(minutes: 2));
    expect(service.peek<String>(PrefetchKey.dataVersion), isNull);
  });

  test('enter 只跑这一栏的任务，失败的任务不影响其余任务', () async {
    final log = <String>[];
    final service = build(
      tasks: {
        PrefetchArea.now: [
          () async => log.add('现在'),
          () async => throw StateError('预读失败'),
        ],
        PrefetchArea.plan: [() async => log.add('安排')],
      },
    );

    service.enter(PrefetchArea.now);
    await pumpEventQueue();
    expect(log, ['现在']);

    service.enter(PrefetchArea.plan);
    await pumpEventQueue();
    expect(log, ['现在', '安排']);
  });

  test('enter 调用的任务通过 warm 留下结果，页面直接取到', () async {
    late final PrefetchService service;
    service = PrefetchService(
      clock: () => now,
      tasks: {
        PrefetchArea.mine: [
          () async => service.warm(PrefetchKey.memory, () async => '预读的一屏'),
        ],
      },
    );

    service.enter(PrefetchArea.mine);
    await pumpEventQueue();

    expect(service.peek<String>(PrefetchKey.memory), '预读的一屏');
  });
}
