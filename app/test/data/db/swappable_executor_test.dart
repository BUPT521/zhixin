import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

part 'swappable_executor_test.g.dart';

/// P0 探针：只验证 drift 的执行器可以在同一个数据库对象下替换。
class ProbeItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
}

@DriftDatabase(tables: [ProbeItems])
class ProbeDb extends _$ProbeDb {
  ProbeDb(super.executor);

  @override
  int get schemaVersion => 1;
}

/// 把内层执行器藏起来，替换库文件时数据库对象与仓库引用保持不变。
class SwappableExecutor implements QueryExecutor {
  SwappableExecutor(this._inner);

  QueryExecutor _inner;
  QueryExecutorUser? _user;

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) {
    _user = user;
    return _inner.ensureOpen(user);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _inner.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _inner.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() => _inner.close();

  Future<void> swap(QueryExecutor next) async {
    final user = _user;
    await _inner.close();
    _inner = next;
    if (user != null) await next.ensureOpen(user);
  }
}

void main() {
  test('换执行器之后同一个数据库对象仍能查询与写入', () async {
    final temp = await Directory.systemTemp.createTemp('zhixin_drift_probe');
    addTearDown(() => temp.delete(recursive: true));

    final secondPath = p.join(temp.path, 'second.sqlite');
    final secondSetup = ProbeDb(NativeDatabase(File(secondPath)));
    await secondSetup
        .into(secondSetup.probeItems)
        .insert(ProbeItemsCompanion.insert(name: 'second'));
    await secondSetup.close();

    final wrapper = SwappableExecutor(
      NativeDatabase(File(p.join(temp.path, 'first.sqlite'))),
    );
    final db = ProbeDb(wrapper);
    await db
        .into(db.probeItems)
        .insert(ProbeItemsCompanion.insert(name: 'first'));
    expect((await db.select(db.probeItems).get()).single.name, 'first');

    await wrapper.swap(NativeDatabase(File(secondPath)));

    final rows = await db.select(db.probeItems).get();
    expect(rows.single.name, 'second');

    await db.transaction(() async {
      await db
          .into(db.probeItems)
          .insert(ProbeItemsCompanion.insert(name: 'third'));
    });
    expect(await db.select(db.probeItems).get(), hasLength(2));

    await db.close();
  });
}
