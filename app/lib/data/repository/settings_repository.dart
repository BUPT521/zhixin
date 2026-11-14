import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/rules/time_format.dart';
import '../db/write_transactions.dart';

/// 保存应用本地设置与内部运行状态。
class SettingsRepository {
  const SettingsRepository(this._db);

  final RawDatabase _db;

  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  AppDatabase _connect() {
    final connection = _db.driftConnection;
    if (connection is AppDatabase) return connection;
    throw StateError('该查询走 drift 生成代码，需要在主库连接上执行');
  }

  Future<int?> cutoffHour() async {
    return _connect().cutoffHour().getSingleOrNull();
  }

  Future<void> setCutoffHour(
    int hour,
    DateTime now, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(transaction, _db).update('profile', {
      'day_cutoff_hour': hour,
      'updated_at': formatDateTime(now),
    }, where: 'id = 1');
  }

  Future<String?> metadata(String key) async {
    return _connect().appMetaValue(key).getSingleOrNull();
  }

  Future<void> setMetadata(String key, String value, DateTime now) async {
    await _db.insert('app_meta', {
      'key': key,
      'value': value,
      'updated_at': formatDateTime(now),
    }, conflictAlgorithm: ConflictAction.replace);
  }
}
