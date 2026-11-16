import 'dart:convert';

import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/assessment.dart';
import '../../domain/rules/uuid_v7.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 一次作答的判断（01 `assessment`）：模型判断与用户提供的核对依据分别保存。
class AssessmentRepository {
  AssessmentRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<String> add({
    required String attemptId,
    required AssessmentKind kind,
    required String result,
    String? basis,
    WriteTransaction? transaction,
  }) async {
    final text = result.trim();
    if (text.isEmpty) throw ArgumentError('判断内容不能为空');
    final now = formatDateTime(_clock());
    final id = newUuidV7();
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertAssessment(
        id,
        attemptId,
        kind.value,
        text,
        basis?.trim(),
        now,
      ),
    );
    return id;
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
    createdAt: requiredDateTime(row.createdAt),
  );

  Future<void> saveUserBasisDraft(
    String attemptId,
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
        await writer.writeGenerated(
          (db) =>
              db.deleteAssessmentsOfKind(attemptId, AssessmentKind.user.value),
        );
      }
      return;
    }
    final now = formatDateTime(_clock());
    if (ids.isEmpty) {
      await writer.writeGenerated(
        (db) => db.insertAssessment(
          newUuidV7(),
          attemptId,
          AssessmentKind.user.value,
          text,
          null,
          now,
        ),
      );
      return;
    }
    await writer.writeGenerated(
      (db) => db.updateAssessmentResult(text, now, ids.first),
    );
    if (ids.length > 1) {
      await writer.writeGenerated(
        (db) => db.deleteAssessmentIds(
          jsonEncode(ids.skip(1).toList(growable: false)),
        ),
      );
    }
  }

  Future<List<Assessment>> forAttempt(String attemptId) async {
    final rows = await _db.selectGenerated(
      (db) => db.assessmentsForAttempt(attemptId).get(),
    );
    return rows.map(_assessmentOf).toList(growable: false);
  }

  /// 一次学习里多次作答的判断，按尝试编号分组给界面用。
  Future<Map<String, List<Assessment>>> forAttempts(
    List<String> attemptIds,
  ) async {
    if (attemptIds.isEmpty) return const {};
    final rows = await _db.selectGenerated(
      (db) => db.assessmentsForAttempts(jsonEncode(attemptIds)).get(),
    );
    final result = <String, List<Assessment>>{};
    for (final row in rows) {
      final assessment = _assessmentOf(row);
      result.putIfAbsent(assessment.attemptId, () => []).add(assessment);
    }
    return result;
  }

  Future<Assessment?> latestOfKind(
    String attemptId,
    AssessmentKind kind,
  ) async {
    final row = await _db.selectGenerated(
      (db) =>
          db.latestAssessmentOfKind(attemptId, kind.value).getSingleOrNull(),
    );
    return row == null ? null : _assessmentOf(row);
  }
}
