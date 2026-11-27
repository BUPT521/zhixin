import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnectionUser;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/db/raw_executor.dart';

import '../../support/test_db.dart';

/// 记录 rawQuery 落在哪个执行器上；外层连接与事务执行器各一份。
class _CountingExecutor implements RawExecutor {
  _CountingExecutor(this.label);

  final String label;
  final List<String> queries = [];

  @override
  DatabaseConnectionUser? get driftConnection => null;

  @override
  Future<int> execute(String sql, [List<Object?>? arguments]) async => 0;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queries.add(sql);
    return [
      {'source': label},
    ];
  }

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      throw UnimplementedError();

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      throw UnimplementedError();
}

class _FakeDatabase implements RawDatabase {
  final _CountingExecutor outer = _CountingExecutor('outer');
  late _CountingExecutor transactionExecutor;
  int transactions = 0;

  @override
  DatabaseConnectionUser? get driftConnection => null;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => outer.rawQuery(sql, arguments);

  @override
  Future<int> execute(String sql, [List<Object?>? arguments]) =>
      outer.execute(sql, arguments);

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      throw UnimplementedError();

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      throw UnimplementedError();

  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) {
    transactions++;
    transactionExecutor = _CountingExecutor('txn');
    return action(transactionExecutor);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('事务内的 rawQuery 使用当前事务执行器', () async {
    final fake = _FakeDatabase();
    final db = GuardedDatabase(gate: DatabaseGate(), resolve: () => fake);

    final inside = await db.transaction(
      (txn) => db.rawQuery('SELECT 1 FROM app_meta'),
    );

    expect(fake.transactions, 1);
    expect(fake.transactionExecutor.queries, ['SELECT 1 FROM app_meta']);
    expect(fake.outer.queries, isEmpty);
    expect(inside.single['source'], 'txn');
  });

  test('事务之外的 rawQuery 走外层连接', () async {
    final fake = _FakeDatabase();
    final db = GuardedDatabase(gate: DatabaseGate(), resolve: () => fake);

    final rows = await db.rawQuery('SELECT 1 FROM app_meta');

    expect(fake.outer.queries, ['SELECT 1 FROM app_meta']);
    expect(rows.single['source'], 'outer');
  });

  test('driftConnection 在事务内外都取当前主库连接', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);

    // 事务之外也是当前主库，按连接直接读的统计不需要事务也能读到。
    expect(rig.db.driftConnection, isA<AppDatabase>());
    expect(rig.db.driftConnection, same(rig.raw.driftConnection));

    final inside = await rig.db.command(
      (txn) async => rig.db.driftConnection,
      label: '读连接',
    );
    expect(inside, isA<AppDatabase>());
  });

  test('只读副本没有 drift 连接，取连接时报用法错误', () async {
    final directory = await Directory.systemTemp.createTemp('zhixin_readonly');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'copy.db');
    final writable = sqlite.sqlite3.open(path)..close();
    expect(writable, isNotNull);

    final copy = openReadOnlyDatabase(path);
    addTearDown(copy.close);
    expect(copy.driftConnection, isNull);
    expect(() => requireAppDatabase(copy), throwsStateError);
  });
}
