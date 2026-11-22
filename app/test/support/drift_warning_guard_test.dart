import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/schema.dart';

import 'drift_warning_guard.dart';

/// 双库检查自己也要有用例：判定用的正是 drift 告警所指的那种情形，即同一个
/// 执行器上建了两个库；各自开库、关库与结构元数据都不该被算进去。
///
/// 同时开着的库登记在全局表里，`setUp` 会检查它；用例自己开出的库都关掉，免得
/// 这一组用例的安排影响后面的用例。
void main() {
  test('同一个执行器上再建一个库会被查出来', () async {
    final executor = NativeDatabase.memory();
    final first = AppDatabase(executor);
    final second = AppDatabase(executor);
    // 两个库共用同一个执行器，关掉任意一个就关了这条连接。
    addTearDown(first.close);

    expect(openDriftDatabases, containsAll([first, second]));
    expect(driftExecutorOf(first), same(driftExecutorOf(second)));
    expect(openSites.keys, contains(first));
    expect(openSites[first], isNotNull, reason: '同时开着的库都要记下它从哪里建出来');

    expect(
      () => expectNoSharedDriftExecutor(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('drift_warning_guard_test.dart'),
            contains('两个 AppDatabase'),
          ),
        ),
      ),
    );
  });

  test('各自开库不算共用执行器，关库之后不再登记', () async {
    final first = AppDatabase.memory();
    final second = AppDatabase.memory();
    expect(driftExecutorOf(first), isNot(same(driftExecutorOf(second))));

    await first.close();
    expect(openDriftDatabases, isNot(contains(first)));
    await second.close();
    expect(openDriftDatabases, isNot(contains(second)));
    expect(() => expectNoSharedDriftExecutor(), returnsNormally);
  });

  test('结构元数据复用同一个实例，而且不计入开着的库', () {
    expect(schemaProbe, same(schemaMetadata));
    expect(openDriftDatabases, isNot(contains(schemaProbe)));
    expect(schemaTableNames(), isNotEmpty);
    expect(schemaIndexNames(), isNotEmpty);
  });
}
