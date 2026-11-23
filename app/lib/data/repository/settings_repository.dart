import '../db/raw_executor.dart';

import '../../domain/rules/time_format.dart';
import '../db/write_transactions.dart';

/// 保存应用本地设置与内部运行状态。
class SettingsRepository {
  const SettingsRepository(this._db);

  final RawDatabase _db;

  Future<int?> cutoffHour() async {
    return _db.selectGenerated((db) => db.cutoffHour().getSingleOrNull());
  }

  Future<void> setCutoffHour(
    int hour,
    DateTime now, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.setCutoffHour('$hour', formatDateTime(now)));
  }

  Future<String?> metadata(String key) async {
    return _db.selectGenerated((db) => db.appMetaValue(key).getSingleOrNull());
  }

  Future<void> setMetadata(
    String key,
    String value,
    DateTime now, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.saveAppMetadata(key, value, formatDateTime(now)),
    );
  }
}
