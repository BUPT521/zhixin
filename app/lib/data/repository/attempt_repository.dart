import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/question.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 作答记录（01 `attempt`）：直接挂在一条学习记录上。
///
/// 题目状态不落库：列表按最近一条已提交尝试判断，错题是派生的筛选结果。
/// 一行未提交的尝试用来挂本次的提示、讲解与草稿，提交时才写答案与自评。
class AttemptRepository {
  AttemptRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<List<Attempt>> attemptsFor(int conversationId) async {
    final rows = await _db.query(
      'attempt',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'id DESC',
    );
    return rows.map(Attempt.fromRow).toList(growable: false);
  }

  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  AppDatabase _connect([RawExecutor? executor]) {
    final connection = (executor ?? _db).driftConnection;
    if (connection is AppDatabase) return connection;
    throw StateError('该查询走 drift 生成代码，需要在主库连接上执行');
  }

  /// 这条记录最近一次学习场次的目标。
  ///
  /// 讨论与作答原先按尝试逐条读场次，一条记录答过几次就多几次读取；这里
  /// 一次联表取最近一个有目标的场次。
  Future<int?> recentSessionGoal(int conversationId) async {
    final rows = await _connect()
        .sessionGoalOfConversation(conversationId)
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// 同一道题以前写下的困难，按提交时间倒序，最多 [limit] 条。
  ///
  /// 只取这道题自己的作答记录，避免其他课程的卡点进入本次上下文；当前这次
  /// 尝试不重复带入。
  Future<List<Attempt>> priorFeedback(
    int conversationId, {
    int? excludeAttemptId,
    int limit = 3,
  }) async {
    final rows = await _db.query(
      'attempt',
      where:
          'conversation_id = ? AND submitted_at IS NOT NULL '
          "AND feedback IS NOT NULL AND TRIM(feedback) != ''",
      whereArgs: [conversationId],
      orderBy: 'submitted_at DESC, id DESC',
      limit: limit + 1,
    );
    return rows
        .map(Attempt.fromRow)
        .where((attempt) => attempt.id != excludeAttemptId)
        .take(limit)
        .toList(growable: false);
  }

  Future<Attempt?> latestSubmitted(int conversationId) async {
    final rows = await _db.query(
      'attempt',
      where: 'conversation_id = ? AND submitted_at IS NOT NULL',
      whereArgs: [conversationId],
      orderBy: 'submitted_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Attempt.fromRow(rows.first);
  }

  Future<Attempt?> attemptById(int id, {WriteTransaction? transaction}) async {
    final rows = await writeExecutor(
      transaction,
      _db,
    ).query('attempt', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Attempt.fromRow(rows.first);
  }

  /// 取这条学习记录里未提交的尝试，没有就建一条。
  ///
  /// 插入与查询在同一个语句里完成：两个“开始作答”同时到达时，后一个的
  /// `WHERE NOT EXISTS` 已经能看到前一个写入的草稿，因此只会留下一条。
  /// 调用方仍应把这段放进一次写入事务里，让场次与草稿属于同一条业务命令。
  Future<Attempt> ensureOpenAttempt(
    int conversationId, {
    int? sessionId,
    int? redoOfAttemptId,
    bool delayed = false,
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    Future<Attempt?> find() async {
      final rows = await writer.query(
        'attempt',
        where: 'conversation_id = ? AND submitted_at IS NULL',
        whereArgs: [conversationId],
        orderBy: 'id DESC',
        limit: 1,
      );
      return rows.isEmpty ? null : Attempt.fromRow(rows.first);
    }

    var attempt = await find();
    if (attempt == null) {
      final now = formatDateTime(_clock());
      await _connect(writer).insertOpenAttempt(
        conversationId,
        sessionId,
        redoOfAttemptId,
        delayed ? 1 : 0,
        now,
        now,
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
    await writer.update(
      'attempt',
      {
        if (sessionChanged) 'session_id': sessionId,
        if (redoChanged) 'redo_of_attempt_id': redoOfAttemptId,
        if (delayedChanged) 'delayed': 1,
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ? AND submitted_at IS NULL',
      whereArgs: [attempt.id],
    );
    return await find() ?? attempt;
  }

  /// 把整份作答草稿留在未提交尝试里：答案、自评与依据一起保存。
  ///
  /// 草稿可以只有自评或依据而没有答案；空字段写回空值，下一次打开时不会
  /// 留下上一次已经清掉的内容。核对依据不属于尝试本身，由调用方写入判断表。
  Future<void> saveDraft(
    int attemptId, {
    required String answer,
    String? solution,
    bool? isCorrect,
    bool? independent,
    bool delayed = false,
    String? feedback,
    WriteTransaction? transaction,
  }) async {
    final text = answer.trim();
    await writeExecutor(transaction, _db).update(
      'attempt',
      {
        'user_answer': text.isEmpty ? null : text,
        'solution': _clean(solution),
        'is_correct': isCorrect == null ? null : (isCorrect ? 1 : 0),
        'independent': independent == null ? null : (independent ? 1 : 0),
        'delayed': delayed ? 1 : 0,
        'feedback': _clean(feedback),
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ? AND submitted_at IS NULL',
      whereArgs: [attemptId],
    );
  }

  Future<void> appendHelp(
    int attemptId,
    HelpEntry help, {
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    final rows = await writer.query(
      'attempt',
      columns: ['help_json'],
      where: 'id = ?',
      whereArgs: [attemptId],
    );
    if (rows.isEmpty) return;
    final helps = HelpEntry.decodeList(rows.first['help_json'] as String?);
    final updated = [...helps, help];
    await writer.update(
      'attempt',
      {
        'help_json': HelpEntry.encodeList(updated),
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [attemptId],
    );
  }

  /// 改写一条尝试上的帮助；确认或收起记忆建议时改动对应那条。
  ///
  /// 帮助列表本身只追加，这里按整份列表写回；没有找到这条尝试或这一条帮助时
  /// 抛出，由调用方决定提示。
  Future<HelpEntry> updateHelp(
    int attemptId,
    int helpIndex,
    HelpEntry Function(HelpEntry help) change, {
    WriteTransaction? transaction,
  }) async {
    final writer = writeExecutor(transaction, _db);
    final rows = await writer.query(
      'attempt',
      columns: ['help_json'],
      where: 'id = ?',
      whereArgs: [attemptId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('未找到这次作答');
    final helps = HelpEntry.decodeList(rows.first['help_json'] as String?);
    if (helpIndex < 0 || helpIndex >= helps.length) {
      throw StateError('未找到这条帮助');
    }
    final updated = change(helps[helpIndex]);
    final list = [...helps]..[helpIndex] = updated;
    await writer.update(
      'attempt',
      {
        'help_json': HelpEntry.encodeList(list),
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [attemptId],
    );
    return updated;
  }

  /// 提交一次作答；对错与独立性都可以留空，未提交尝试才补齐字段。
  Future<int> submit(
    int attemptId, {
    required String answer,
    String? solution,
    required bool? isCorrect,
    required bool? independent,
    bool delayed = false,
    String? feedback,
    WriteTransaction? transaction,
  }) async {
    final now = formatDateTime(_clock());
    return writeExecutor(transaction, _db).update(
      'attempt',
      {
        'user_answer': answer.trim(),
        'solution': _clean(solution),
        'is_correct': isCorrect == null ? null : (isCorrect ? 1 : 0),
        'independent': independent == null ? null : (independent ? 1 : 0),
        'delayed': delayed ? 1 : 0,
        'feedback': _clean(feedback),
        'submitted_at': now,
        'updated_at': now,
      },
      where: 'id = ? AND submitted_at IS NULL',
      whereArgs: [attemptId],
    );
  }

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
