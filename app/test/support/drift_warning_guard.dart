import 'package:drift/drift.dart' show QueryExecutor, driftRuntimeOptions;
import 'package:zhixin/data/db/drift/app_database.dart';

/// 双库告警的测试守卫：关掉 drift 自带的打印，换成“同一个执行器才算问题”的检查。
///
/// drift 在构造第二个同类库时打印告警，判定只看运行时类型计数、只在 `close()`
/// 时减一，记数又只在 `assert` 里做。前一个用例的库没来得及关、用例里同时多开
/// 一台设备、或者构造过结构元数据实例，都会让计数大于一，正常用例照样告警；
/// 真正危险的“同一个执行器上开了两个库”因此淹没在几十条误报里。
///
/// 这里按执行器判断：同时开着的库登记在 `openSites`，每组用例开始时检查一遍，
/// 同一个执行器上出现两个库直接让用例失败；同时开着几个互相独立的库不报。
/// `logStatements` 一类打印也走 drift 的 `debugPrint`，本仓没有开启，关掉不影响
/// 其他输出。
void installDriftWarningGuard() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  driftRuntimeOptions.debugPrint = (_) {};
}

/// 检查同时开着的库是否共用一个执行器；详见 [installDriftWarningGuard]。
void expectNoSharedDriftExecutor() {
  final seen = <QueryExecutor, AppDatabase>{};
  for (final database in openDriftDatabases) {
    final executor = driftExecutorOf(database);
    final first = seen[executor];
    if (first == null) {
      seen[executor] = database;
      continue;
    }
    throw StateError(
      '同一个执行器上开了两个 AppDatabase，会抢同一个库文件的事务：\n'
      '  先开的 ${openSites[first]}\n'
      '  后开的 ${openSites[database]}',
    );
  }
}
