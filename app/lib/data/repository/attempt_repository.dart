import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/question.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/text.dart';
import '../../domain/rules/uuid_v7.dart';
import '../db/write_transactions.dart';

/// 作答记录（01 `attempt`）：直接挂在一条学习记录上。
///
/// 题目状态不落库：列表按最近一条已提交尝试判断，错题是派生的筛选结果。
/// 一行未提交的尝试用来挂本次的提示、讲解与草稿，提交时才写答案与自评。
class AttemptRepository {
  AttemptRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<List<Attempt>> attemptsFor(String conversationId) async {
    final rows = await _db.selectGenerated(
      (db) => db.attemptsForConversation(conversationId).get(),
    );
    return rows.map(_attemptOf).toList(growable: false);
  }

  /// 表行直接还原成模型；布尔列已经是 bool，提示条目统一走 [HelpEntry.decodeList]。
  static Attempt _attemptOf(AttemptRow row) => Attempt(
    id: row.id,
    conversationId: row.conversationId,
    sessionId: row.sessionId,
    redoOfAttemptId: row.redoOfAttemptId,
    userAnswer: row.userAnswer,
    solution: row.solution,
    isCorrect: row.isCorrect,
    independent: row.independent,
    helps: HelpEntry.decodeList(row.helpJson),
    feedback: row.feedback,
    delayed: row.delayed,
    submittedAt: optionalDateTime(row.submittedAt),
    createdAt: optionalDateTime(row.createdAt),
  );

  /// 这条记录最近一次学习场次的目标。
  ///
  /// 讨论与作答原先按尝试逐条读场次，一条记录答过几次就多几次读取；这里
  /// 一次联表取最近一个有目标的场次。
  Future<String?> recentSessionGoal(String conversationId) async {
    final rows = await _db.selectGenerated(
      (db) => db.sessionGoalOfConversation(conversationId).get(),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 同一道题以前写下的困难，按提交时间倒序，最多 [limit] 条。
  ///
  /// 只取这道题自己的作答记录，避免其他课程的卡点进入本次上下文；当前这次
  /// 尝试不重复带入。
  Future<List<Attempt>> priorFeedback(
    String conversationId, {
    String? excludeAttemptId,
    int limit = 3,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db.priorFeedback(conversationId, limit + 1).get(),
    );
    return rows
        .map(_attemptOf)
        .where((attempt) => attempt.id != excludeAttemptId)
        .take(limit)
        .toList(growable: false);
  }

  Future<Attempt?> latestSubmitted(String conversationId) async {
    final row = await _db.selectGenerated(
      (db) => db.latestSubmittedAttempt(conversationId).getSingleOrNull(),
    );
    return row == null ? null : _attemptOf(row);
  }

  Future<Attempt?> attemptById(
    String id, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final row = await executor.selectGenerated(
      (db) => db.attemptById(id).getSingleOrNull(),
    );
    return row == null ? null : _attemptOf(row);
  }

  /// 取这条学习记录里未提交的尝试，没有就建一条。
  ///
  /// 插入与查询在同一个语句里完成：两个“开始作答”同时到达时，后一个的
  /// `WHERE NOT EXISTS` 已经能看到前一个写入的草稿，因此只会留下一条。
  /// 调用方仍应把这段放进一次写入事务里，让场次与草稿属于同一条业务命令。
  Future<Attempt> ensureOpenAttempt(
    String conversationId, {
    String? sessionId,
    String? redoOfAttemptId,
    bool delayed = false,
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    Future<Attempt?> find() async {
      final row = await writer.selectGenerated(
        (db) => db.openAttempt(conversationId).getSingleOrNull(),
      );
      return row == null ? null : _attemptOf(row);
    }

    var attempt = await find();
    if (attempt == null) {
      final now = formatDateTime(_clock());
      await writer.writeGenerated(
        (db) => db.insertOpenAttempt(
          newUuidV7(),
          conversationId,
          sessionId,
          redoOfAttemptId,
          delayed,
          now,
          now,
        ),
      );
      attempt = await find();
      if (attempt == null) {
        throw StateError('这次作答没有建立草稿，请重新打开题目');
      }
    }
    final sessionChanged = sessionId != null && attempt.sessionId != sessionId;
    final redoChanged =
        redoOfAttemptId != null && attempt.redoOfAttemptId != redoOfAttemptId;
    final delayedChanged = delayed && !attempt.delayed;
    if (!sessionChanged && !redoChanged && !delayedChanged) return attempt;
    final attemptId = attempt.id;
    final stamp = formatDateTime(_clock());
    await writer.writeGenerated(
      (db) => db.updateOpenAttemptContext(
        sessionChanged ? sessionId : null,
        redoChanged ? redoOfAttemptId : null,
        delayedChanged ? true : null,
        stamp,
        attemptId,
      ),
    );
    return await find() ?? attempt;
  }

  /// 把整份作答草稿留在未提交尝试里：答案、自评与依据一起保存。
  ///
  /// 草稿可以只有自评或依据而没有答案；空字段写回空值，下一次打开时不会
  /// 留下上一次已经清掉的内容。核对依据不属于尝试本身，由调用方写入判断表。
  Future<void> saveDraft(
    String attemptId, {
    required String answer,
    String? solution,
    bool? isCorrect,
    bool? independent,
    bool delayed = false,
    String? feedback,
    WriteTransaction? transaction,
  }) async {
    final text = answer.trim();
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.saveOpenAttemptDraft(
        nullableText(text),
        nullableText(solution),
        isCorrect,
        independent,
        delayed,
        nullableText(feedback),
        stamp,
        attemptId,
      ),
    );
  }

  Future<void> appendHelp(
    String attemptId,
    HelpEntry help, {
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    // 取整行而不是只取 help_json：这一列本身可空，空表示还没有帮助，
    // 与“没有这次作答”是两回事。
    final row = await writer.selectGenerated(
      (db) => db.attemptById(attemptId).getSingleOrNull(),
    );
    if (row == null) return;
    final helps = HelpEntry.decodeList(row.helpJson);
    final updated = [...helps, help];
    final stamp = formatDateTime(_clock());
    await writer.writeGenerated(
      (db) =>
          db.setAttemptHelp(HelpEntry.encodeList(updated), stamp, attemptId),
    );
  }

  /// 改写一条尝试上的帮助；确认或收起记忆建议时改动对应那条。
  ///
  /// 帮助列表本身只追加，这里按整份列表写回；没有找到这条尝试或这一条帮助时
  /// 抛出，由调用方决定提示。
  Future<HelpEntry> updateHelp(
    String attemptId,
    int helpIndex,
    HelpEntry Function(HelpEntry help) change, {
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    final row = await writer.selectGenerated(
      (db) => db.attemptById(attemptId).getSingleOrNull(),
    );
    if (row == null) throw StateError('未找到这次作答');
    final helps = HelpEntry.decodeList(row.helpJson);
    if (helpIndex < 0 || helpIndex >= helps.length) {
      throw StateError('未找到这条帮助');
    }
    final updated = change(helps[helpIndex]);
    final list = [...helps]..[helpIndex] = updated;
    final stamp = formatDateTime(_clock());
    await writer.writeGenerated(
      (db) => db.setAttemptHelp(HelpEntry.encodeList(list), stamp, attemptId),
    );
    return updated;
  }

  /// 提交一次作答；对错与独立性都可以留空，未提交尝试才补齐字段。
  Future<int> submit(
    String attemptId, {
    required String answer,
    String? solution,
    required bool? isCorrect,
    required bool? independent,
    bool delayed = false,
    String? feedback,
    WriteTransaction? transaction,
  }) async {
    final now = formatDateTime(_clock());
    return writeExecutor(transaction, _db).writeGenerated(
      (db) => db.submitOpenAttempt(
        answer.trim(),
        nullableText(solution),
        isCorrect,
        independent,
        delayed,
        nullableText(feedback),
        now,
        attemptId,
      ),
    );
  }
}
