import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnectionUser;

import '../revisions/revision_engine.dart';
import '../../domain/models/revision_models.dart';
import 'database_gate.dart';
import 'drift/app_database.dart';
import 'live_queries.dart';
import 'raw_executor.dart';

/// 把整库访问收进 [DatabaseGate]：读共享，写、事务与关闭独占（01 第 7 章）。
///
/// 仓库与页面只拿这一个对象，不直接持有连接：恢复流程替换连接之后，[resolve]
/// 指向新连接，排队的写入在新库上继续，不会打到已经关闭的旧库。
///
/// 每次独立写入或命令事务由 [RevisionEngine] 建立提交上下文，业务行与版本
/// 明细一起提交；事务回调里再次写入直接使用本次事务，不再排队，也不会另开
/// 一个提交。
class GuardedDatabase implements RawDatabase {
  GuardedDatabase({
    required this.gate,
    required this.resolve,
    this.revisions,
    this.defaultAction = '数据写入',
  });

  final DatabaseGate gate;

  /// 取当前连接；恢复替换期间由调用方切到新连接。
  final RawDatabase Function() resolve;

  /// 数据版本引擎；为空的旧测试入口只执行原始 SQL。
  RevisionEngine? revisions;

  /// 没有显式业务动作时的提交说明。
  final String defaultAction;

  /// 一次带净变化的提交落库之后回调改到的表，在独占区释放之前调用。
  ///
  /// 应用根用它把语义索引的补建排进安静期；回滚的写入与没有净变化的写入不
  /// 调用，整库恢复与清空换库之后由调用方另行通知（ADR-0014 第 2、3 条）。
  void Function(Set<String> tables)? onCommitted;

  static final Object _txnScope = Object();

  RawDatabase get _db => resolve();

  /// 表变更通知与跟随更新的读取；库连接换掉之后由应用根调用 [connectionReplaced]。
  late final TableChanges _changes = TableChanges();

  late final LiveQueries _live = LiveQueries(
    changes: _changes.stream,
    run: _readAfterCommit,
  );

  /// 跟随写入更新的读取入口；应用服务经运行环境使用（ADR-0014）。
  LiveQueries get live => _live;

  /// 提交之后的重读：登记成读者，后面排队的写入等它读完再开始。
  ///
  /// 读取本身在发出通知的执行区里执行，因此与写入共用同一个事件循环，
  /// 不会出现“读取等 pump、写入等读取”的互等。
  Future<T> _readAfterCommit<T>(Future<T> Function() read) =>
      gate.shared(read, newReader: true);

  /// 当前 drift 连接：事务内是本次事务的连接，事务之外是当前主库的连接。
  ///
  /// 这是唯一一个“取连接”的入口，[selectGenerated] 与 [writeGenerated] 都经它
  /// 落库；它自己不经访问协调，需要与恢复、清空互斥的读写请走那两个方法。只读
  /// 副本与测试里的原始执行器没有 drift 主库，返回空。
  @override
  DatabaseConnectionUser? get driftConnection {
    final connection = _currentTxn?.driftConnection ?? _db.driftConnection;
    assert(
      connection == null || connection is AppDatabase,
      '生成查询只能落在 drift 主库上；只读副本与原始执行器没有仓库查询',
    );
    return connection;
  }

  /// 等共享访问获准后再取连接，恢复期间排队的读取会访问新库。
  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      gate.shared(() => query(requireAppDatabase(_currentTxn ?? _db)));

  /// 独立写语句形成一个提交；事务里的写直接使用本次事务。
  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      _write((executor) => query(requireAppDatabase(executor)));

  RawExecutor? get _currentTxn => Zone.current[_txnScope] as RawExecutor?;

  /// 版本引擎、备份与撤销使用的执行器就是本对象本身。
  RawExecutor get raw => this;

  /// 跟随写入更新的读取；读取经共享访问执行，与恢复、清空的独占区互斥。
  ///
  /// 只有应用根的主连接提供这条路：仓库与页面拿的是本对象，只读副本与单条
  /// 语句的执行器没有订阅者，不实现（ADR-0014）。
  Stream<T> watch<T>({
    required Set<String> tables,
    required Future<T> Function() read,
  }) => _live.watch(tables: tables, read: read);

  /// 一批已经提交的表变更：提交成功之后、独占区释放之前发布。
  ///
  /// 整库恢复、导入与撤销这类不经过命令的表级改动由调用方在事务结束之后
  /// 直接调用，[notifyAllTables] 是它们常用的形式（ADR-0014 第 3 条）。
  void notifyTables(Iterable<String> tables) => _changes.publish(tables);

  /// 全部业务表通知一次：整份换数据之后用。
  void notifyAllTables() => _changes.connectionReplaced();

  /// 库连接被换掉（整库恢复、清空之后重新打开）：按全部表补发一次，
  /// 订阅中的页面因此在新库上重读。
  ///
  /// 恢复流程会先关掉当前连接再打开新库，[close] 的“已关闭”标记随之复位，
  /// 通知流本身不随连接替换关闭，订阅中的页面继续收到重读。
  void connectionReplaced() {
    _closed = false;
    _live.muted = false;
    _changes.connectionReplaced();
  }

  /// 关闭连接：等正在进行的读写结束；恢复流程里已经在独占区，直接执行。
  ///
  /// 页面退出与测试清理都会各关一次，第二次直接返回，不再重关连接；恢复与
  /// 清空换库之后由 [connectionReplaced] 复位，新连接照常可以关。关之前先
  /// 停掉订阅的重读：库关掉之后再有读取进来，drift 会把连接重新打开，
  /// 测试收尾删临时目录时表现为文件被占用。
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _live.muted = true;
    await gate.closeExclusive(() => _db.close());
  }

  bool _closed = false;

  /// 事务一律按独占执行：事务里通常要写，读到的也必须是同一时刻的状态。
  ///
  /// 只读的事务不预留提交编号；有净变化时由收尾就地分配（R1）。
  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) async =>
      (await _run(action)).value;

  /// 带业务动作标签的命令；一次动作修改多张表时仍只形成一个提交。
  ///
  /// [kind] 是提交类型，远端提交应用走 [RevisionKind.remote]，其余入口默认是
  /// 普通写入。[uid] 是这个动作的提交身份：界面在动作开始时生成 UUIDv7 并一路
  /// 传下来，重试沿用同一个值；已经有这条提交时不再执行写入，提供 [onDuplicate]
  /// 时由调用方把原提交还原成同样的结果，否则抛出 [RevisionDuplicateRequest]
  /// （ADR-0053 决定第 3 条）。
  Future<T> command<T>(
    Future<T> Function(RawExecutor txn) action, {
    required String label,
    String actor = 'user',
    String? uid,
    RevisionKind kind = RevisionKind.write,
    T Function(RevisionCommit commit)? onDuplicate,
  }) async => (await commandOutcome(
    action,
    label: label,
    actor: actor,
    uid: uid,
    kind: kind,
    onDuplicate: onDuplicate,
  )).value;

  /// 与 [command] 相同，另外交出这次命令对应的提交。
  ///
  /// [commit] 是这次落库的提交；请求重试时是原提交；没有净变化时为空。
  /// [WriteTransactions.run] 用它把提前预留但最终没有落库的回执改成跳过。
  Future<({T value, RevisionCommit? commit})> commandOutcome<T>(
    Future<T> Function(RawExecutor txn) action, {
    required String label,
    String actor = 'user',
    String? uid,
    RevisionKind kind = RevisionKind.write,
    T Function(RevisionCommit commit)? onDuplicate,
  }) => _run(
    action,
    label: label,
    actor: actor,
    uid: uid,
    kind: kind,
    onDuplicate: onDuplicate,
  );

  Future<({T value, RevisionCommit? commit})> _run<T>(
    Future<T> Function(RawExecutor txn) action, {
    String? label,
    String actor = 'user',
    String? uid,
    RevisionKind kind = RevisionKind.write,
    T Function(RevisionCommit commit)? onDuplicate,
  }) {
    final active = _currentTxn;
    if (active != null) {
      throw StateError('数据库事务不能嵌套；当前写入请使用传入的 WriteTransaction');
    }
    final engine = revisions;
    return gate
        .exclusive(() {
          if (engine == null) {
            return _db.transaction<({T value, RevisionCommit? commit})>(
              (txn) async => (
                value: await runZoned(
                  () => action(txn),
                  zoneValues: {_txnScope: txn},
                ),
                commit: null,
              ),
            );
          }
          final changed = <String>{};
          return _db
              .transaction<({T value, RevisionCommit? commit})>((txn) async {
                if (uid != null && uid.isNotEmpty) {
                  final existing = await engine.commitByUid(txn, uid);
                  if (existing != null) {
                    if (onDuplicate != null) {
                      return (value: onDuplicate(existing), commit: existing);
                    }
                    throw RevisionDuplicateRequest(existing);
                  }
                }
                await engine.beginCommand(txn, uid: uid);
                RevisionCommit? formed;
                final value = await runZoned(() async {
                  final result = await action(txn);
                  formed = await engine.finishCommand(
                    txn,
                    action: label ?? defaultAction,
                    actor: actor,
                    uid: uid,
                    changedTables: changed,
                    kind: kind,
                  );
                  return result;
                }, zoneValues: {_txnScope: txn});
                return (value: value, commit: formed);
              })
              .then((outcome) {
                // 提交已经落库、独占区还没释放：这时发布表变更，订阅中的读取都排在
                // 独占区之后，读到的就是这次提交之后的数据（ADR-0014 第 2 条）。
                _changes.publish(changed);
                final committed = onCommitted;
                if (committed != null && changed.isNotEmpty) committed(changed);
                return outcome;
              });
        })
        .then((outcome) async {
          // 独占区已经释放；空闲检查点与检索索引补建在这里做，不占用写事务
          // （ADR-0039 第 2 条）。
          if (engine != null) await engine.afterCommitIdle(_db);
          return outcome;
        });
  }

  /// 独立的写语句各自形成一个提交；事务里的写直接使用本次事务。
  Future<T> _write<T>(Future<T> Function(RawExecutor executor) action) {
    final active = _currentTxn;
    if (active != null) return action(active);
    return transaction(action);
  }

  bool _rawReplaceOnVersioned(String sql) {
    final normalized = sql.trimLeft().toUpperCase();
    final replace =
        normalized.startsWith('REPLACE') ||
        RegExp(r'^INSERT\s+OR\s+REPLACE').hasMatch(normalized);
    if (!replace) return false;
    final lower = sql.toLowerCase();
    return versionedTableNames.any(
      (table) => RegExp('\\b${RegExp.escape(table)}\\b').hasMatch(lower),
    );
  }

  @override
  Future<int> execute(String sql, [List<Object?>? arguments]) {
    if (_rawReplaceOnVersioned(sql)) {
      throw ArgumentError('版本化表不能使用 REPLACE，请改用 insert、update 或 UPSERT');
    }
    return _write((executor) => executor.execute(sql, arguments));
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    // 事务里读的必须是本次事务写下的数据：外层连接在这个回调里可能正被事务
    // 占用，也可能读到提交之前的旧状态，所以与 execute 一样优先取当前执行器。
    final active = _currentTxn;
    if (active != null) return active.rawQuery(sql, arguments);
    return gate.shared(() => _db.rawQuery(sql, arguments));
  }
}
