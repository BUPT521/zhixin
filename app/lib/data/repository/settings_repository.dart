import 'package:sqflite/sqflite.dart';

import '../../domain/rules/time_format.dart';
import '../db/write_transactions.dart';

/// 保存应用本地设置与内部运行状态。
class SettingsRepository {
  const SettingsRepository(this._db);

  final Database _db;

  Future<int?> cutoffHour() async {
    final rows = await _db.query(
      'profile',
      columns: ['day_cutoff_hour'],
      where: 'id = 1',
    );
    return rows.isEmpty ? null : rows.single['day_cutoff_hour'] as int?;
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
    final rows = await _db.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String?;
  }

  Future<void> setMetadata(String key, String value, DateTime now) async {
    await _db.insert('app_meta', {
      'key': key,
      'value': value,
      'updated_at': formatDateTime(now),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
