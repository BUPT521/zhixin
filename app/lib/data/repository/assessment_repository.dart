import '../db/raw_executor.dart';

import '../../domain/models/assessment.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 一次作答的判断（01 `assessment`）：模型判断与用户提供的核对依据分别保存。
class AssessmentRepository {
  AssessmentRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<int> add({
    required int attemptId,
    required AssessmentKind kind,
    required String result,
    String? basis,
    WriteTransaction? transaction,
  }) async {
    final text = result.trim();
    if (text.isEmpty) throw ArgumentError('判断内容不能为空');
    final now = formatDateTime(_clock());
    return writeExecutor(transaction, _db).insert('assessment', {
      'attempt_id': attemptId,
      'kind': kind.value,
      'result': text,
      'basis': basis?.trim(),
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 草稿里的核对依据：有内容时写进这次尝试，清空时删掉，提交时沿用同一条。
  ///
  /// 未提交的尝试也可以有用户填写的核对依据，它与模型判断共用一张表，
  /// 因此提交时更新原来的行，避免同一次作答出现两条依据。
  Future<void> saveUserBasisDraft(
    int attemptId,
    String? result, {
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    final attemptRows = await writer.query(
      'attempt',
      columns: ['submitted_at'],
      where: 'id = ?',
      whereArgs: [attemptId],
      limit: 1,
    );
    if (attemptRows.isEmpty) throw StateError('未找到这次作答');
    if (attemptRows.single['submitted_at'] != null) {
      throw StateError('这次作答已经提交，核对依据不能再改');
    }
    final text = result?.trim();
    final rows = await writer.query(
      'assessment',
      columns: ['id'],
      where: 'attempt_id = ? AND kind = ?',
      whereArgs: [attemptId, AssessmentKind.user.value],
      orderBy: 'id DESC',
    );
    if (text == null || text.isEmpty) {
      if (rows.isNotEmpty) {
        await writer.delete(
          'assessment',
          where: 'attempt_id = ? AND kind = ?',
          whereArgs: [attemptId, AssessmentKind.user.value],
        );
      }
      return;
    }
    final now = formatDateTime(_clock());
    if (rows.isEmpty) {
      await writer.insert('assessment', {
        'attempt_id': attemptId,
        'kind': AssessmentKind.user.value,
        'result': text,
        'created_at': now,
        'updated_at': now,
      });
      return;
    }
    await writer.update(
      'assessment',
      {'result': text, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
    if (rows.length > 1) {
      await writer.delete(
        'assessment',
        where: 'id IN (${List.filled(rows.length - 1, '?').join(', ')})',
        whereArgs: [for (final row in rows.skip(1)) row['id']],
      );
    }
  }

  Future<List<Assessment>> forAttempt(int attemptId) async {
    final rows = await _db.query(
      'assessment',
      where: 'attempt_id = ?',
      whereArgs: [attemptId],
      orderBy: 'id',
    );
    return rows.map(Assessment.fromRow).toList(growable: false);
  }

  /// 一次学习里多次作答的判断，按尝试编号分组给界面用。
  Future<Map<int, List<Assessment>>> forAttempts(List<int> attemptIds) async {
    if (attemptIds.isEmpty) return const {};
    final placeholders = List.filled(attemptIds.length, '?').join(', ');
    final rows = await _db.query(
      'assessment',
      where: 'attempt_id IN ($placeholders)',
      whereArgs: attemptIds,
      orderBy: 'id',
    );
    final result = <int, List<Assessment>>{};
    for (final row in rows) {
      final assessment = Assessment.fromRow(row);
      result.putIfAbsent(assessment.attemptId, () => []).add(assessment);
    }
    return result;
  }

  Future<Assessment?> latestOfKind(int attemptId, AssessmentKind kind) async {
    final rows = await _db.query(
      'assessment',
      where: 'attempt_id = ? AND kind = ?',
      whereArgs: [attemptId, kind.value],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Assessment.fromRow(rows.first);
  }
}
