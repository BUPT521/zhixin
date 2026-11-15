import 'dart:convert';

import '../db/drift/app_database.dart';
import '../db/drift/drift_raw.dart';
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
  /// 生成的结果行是表行类型，字段与领域模型同名，只补派生值。
  static Assessment _assessmentOf(AssessmentRow row) => Assessment(
    id: row.id,
    attemptId: row.attemptId,
    kind: AssessmentKind.fromValue(row.kind),
    result: row.result,
    basis: row.basis,
    createdAt: DateTime.tryParse(row.createdAt),
  );

  Future<void> saveUserBasisDraft(
    int attemptId,
    String? result, {
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    final submission = await writer.selectGenerated(
      (db) => db.attemptSubmission(attemptId).getSingleOrNull(),
    );
    if (submission == null) throw StateError('未找到这次作答');
    if (submission.submittedAt != null) {
      throw StateError('这次作答已经提交，核对依据不能再改');
    }
    final text = result?.trim();
    final ids = await writer.selectGenerated(
      (db) =>
          db.assessmentIdsOfKind(attemptId, AssessmentKind.user.value).get(),
    );
    if (text == null || text.isEmpty) {
      if (ids.isNotEmpty) {
        await writer.delete(
          'assessment',
          where: 'attempt_id = ? AND kind = ?',
          whereArgs: [attemptId, AssessmentKind.user.value],
        );
      }
      return;
    }
    final now = formatDateTime(_clock());
    if (ids.isEmpty) {
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
      whereArgs: [ids.first],
    );
    if (ids.length > 1) {
      await writer.delete(
        'assessment',
        where: 'id IN (${List.filled(ids.length - 1, '?').join(', ')})',
        whereArgs: ids.skip(1).toList(growable: false),
      );
    }
  }

  Future<List<Assessment>> forAttempt(int attemptId) async {
    final rows = await _db.selectGenerated(
      (db) => db.assessmentsForAttempt(attemptId).get(),
    );
    return rows.map(_assessmentOf).toList(growable: false);
  }

  /// 一次学习里多次作答的判断，按尝试编号分组给界面用。
  Future<Map<int, List<Assessment>>> forAttempts(List<int> attemptIds) async {
    if (attemptIds.isEmpty) return const {};
    final rows = await _db.selectGenerated(
      (db) => db.assessmentsForAttempts(jsonEncode(attemptIds)).get(),
    );
    final result = <int, List<Assessment>>{};
    for (final row in rows) {
      final assessment = _assessmentOf(row);
      result.putIfAbsent(assessment.attemptId, () => []).add(assessment);
    }
    return result;
  }

  Future<Assessment?> latestOfKind(int attemptId, AssessmentKind kind) async {
    final row = await _db.selectGenerated(
      (db) =>
          db.latestAssessmentOfKind(attemptId, kind.value).getSingleOrNull(),
    );
    return row == null ? null : _assessmentOf(row);
  }
}
