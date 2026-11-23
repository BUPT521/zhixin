import 'dart:async';

import '../data/db/drift/app_database.dart';
import '../data/db/raw_executor.dart';
import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/revisions/revision_models.dart';
import '../domain/models/memory.dart';
import '../domain/rules/content_identity.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';

/// 记忆的使用记录种类（01 `memory_use.kind`）：进入相关层、由 `search_memory`
/// 读到。
enum MemoryUseKind {
  recall('recall'),
  search('search');

  const MemoryUseKind(this.value);

  final String value;

  bool get isRecall => this == MemoryUseKind.recall;
}

/// 未登录时使用的本机设备标识。
///
/// `AccountService.deviceId()` 未登录时同样能给出这台设备的编号；只有取不到
/// 账号服务（例如登录凭据不可用）时才用这个标识，保证未登录也按设备记统计。
const String localMemoryUsageDeviceId = 'local';

/// 记忆使用统计（ADR-0051 决定第 8 条）。
///
/// 召回进入相关层与被 `search_memory` 读到的次数先记在内存与本机：每次使用先
/// 在内存里累加，再写一行 `memory_use`（一台设备一行，`used_at` 是使用的时刻，
/// `acquired_at` 是本机拿到它的时刻，写完不再改）。计数不在这里累进
/// `memory_usage`，也不在每次召回时形成提交；冲刷时取本设备
/// `acquired_at > first_seen_at` 的记录现算，按种类分别加进 `recall_count` 与
/// `search_count`，更新 `last_*_at`，并把 `first_seen_at` 推进到本次冲刷时刻，
/// 所以重复冲刷不会重复计数。
///
/// 冲刷只在应用进入后台、且距上次冲刷不少于 [flushInterval] 时进行，形成一条
/// `maintenance`、`system` 的提交，不另外触发同步。设备编号取 [deviceIdSource]
/// （运行时是 `AccountService.deviceId()`）；取不到就跳过冲刷。
class MemoryUsageService {
  MemoryUsageService({
    required this.db,
    required this.transactions,
    required this.deviceIdSource,
    this.clock = systemClock,
    this.flushInterval = const Duration(days: 1),
    this.onFlushed,
    this.storedFlushAt,
    this.recordFlushAt,
  });

  final RawDatabase db;
  final WriteTransactions transactions;

  /// 本机设备标识的来源；运行时是 `AccountService.deviceId()`。
  final Future<String?> Function() deviceIdSource;
  final Clock clock;

  /// 两次冲刷之间最少间隔多少时间；“一天”是初值，按内测数据调整。
  final Duration flushInterval;

  /// 冲刷之后通知别处（记忆索引按本机记录重建）；为空时什么都不做。
  final Future<void> Function()? onFlushed;

  /// 读上次冲刷时刻的持久化入口；为空时只看本次运行。
  final Future<DateTime?> Function()? storedFlushAt;

  /// 记下上次冲刷时刻的持久化入口；为空时只看本次运行。
  final Future<void> Function(DateTime at)? recordFlushAt;

  /// 本次运行里记下、还没冲刷的次数，按记忆编号分开；用于观察与测试。
  final Map<String, int> _pendingRecalls = {};
  final Map<String, int> _pendingSearches = {};

  /// 写使用记录的队列：每次召回只排一行写入，输出按出现顺序，不在回答路上等。
  Future<void> _writes = Future<void>.value();

  String? _deviceId;

  /// 最近一次记下的使用时刻；同一秒里的连续使用从这里往后错开。
  DateTime? _lastUseAt;
  DateTime? _lastFlushAt;
  bool _flushing = false;

  /// 本次运行里相关层用到过几次，全部记忆合计。
  int get pendingRecallCount =>
      _pendingRecalls.values.fold(0, (sum, count) => sum + count);

  /// 本次运行里主动搜索读到过几次，全部记忆合计。
  int get pendingSearchCount =>
      _pendingSearches.values.fold(0, (sum, count) => sum + count);

  /// 上次冲刷的时刻；没有冲刷过时为空。
  DateTime? get lastFlushAt => _lastFlushAt;

  /// 一条记忆进入相关层。
  void noteRecall(String memoryId, {DateTime? at}) =>
      _note(MemoryUseKind.recall, memoryId, at);

  /// 一条记忆被 `search_memory` 读到。
  void noteSearch(String memoryId, {DateTime? at}) =>
      _note(MemoryUseKind.search, memoryId, at);

  /// 一次回答进入相关层的记忆逐条记一次。
  void noteRecalled(Iterable<Memory> memories, {DateTime? at}) {
    for (final memory in memories) {
      noteRecall(memory.id, at: at);
    }
  }

  void _note(MemoryUseKind kind, String memoryId, DateTime? at) {
    final counts = kind.isRecall ? _pendingRecalls : _pendingSearches;
    counts.update(memoryId, (value) => value + 1, ifAbsent: () => 1);
    // 同一秒里连着记几次时，时刻在场内就往后错开；写进库的编号与时刻因此
    // 各不相同，不会被“同编号即同一行”的去重吃掉。
    final now = at ?? clock();
    final last = _lastUseAt;
    final usedAt = last != null && !now.isAfter(last)
        ? last.add(const Duration(seconds: 1))
        : now;
    _lastUseAt = usedAt;
    _writes = _writes.then(
      (_) => _writeUse(kind, memoryId, formatDateTime(usedAt)),
    );
  }

  /// 写一行使用记录；记账或库暂时不可用时只丢这一行，不影响回答。
  ///
  /// 每行按“设备＋记忆编号＋种类＋时刻”算出固定编号：两台设备同一秒读到同一条
  /// 记忆时不会撞主键（ADR-0053 的提交身份规则同一条思路）。
  Future<void> _writeUse(
    MemoryUseKind kind,
    String memoryId,
    String usedAt,
  ) async {
    final device = await _accountDeviceId();
    if (device == null) return;
    try {
      await db.transaction(
        (txn) => txn.selectGenerated(
          (db) => db.insertMemoryUse(
            _useId(device, memoryId, kind, usedAt),
            memoryId,
            device,
            kind.value,
            usedAt,
            usedAt,
          ),
        ),
      );
    } catch (_) {
      return;
    }
    final counts = kind.isRecall ? _pendingRecalls : _pendingSearches;
    final remaining = (counts[memoryId] ?? 0) - 1;
    if (remaining <= 0) {
      counts.remove(memoryId);
    } else {
      counts[memoryId] = remaining;
    }
  }

  /// 一行使用记录的编号：同一设备在同一条记忆上用同一种方式的同一时刻是同一行。
  static String _useId(
    String deviceId,
    String memoryId,
    MemoryUseKind kind,
    String usedAt,
  ) => contentHash(
    'memory-use\n$deviceId\n$memoryId\n${kind.value}\n$usedAt'.codeUnits,
  );

  /// 本机设备标识：优先用账号服务给的设备编号（未登录也有），取不到时退到
  /// 固定的本机标识，因此未登录也按设备记统计（ADR-0051 决定第 8 条）。
  Future<String> deviceId() async {
    final cached = _deviceId;
    if (cached != null) return cached;
    String? resolved;
    try {
      final id = await deviceIdSource();
      final trimmed = id?.trim() ?? '';
      if (trimmed.isNotEmpty) resolved = trimmed;
    } catch (_) {
      resolved = null;
    }
    final value = resolved ?? localMemoryUsageDeviceId;
    _deviceId = value;
    return value;
  }

  /// 只问账号服务，不回落本机标识：写入与冲刷用它判断“取不到设备编号就跳过”。
  Future<String?> _accountDeviceId() async {
    try {
      final id = await deviceIdSource();
      final trimmed = id?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// 应用进入后台时调用：距上次冲刷不足一天时跳过。
  ///
  /// 上次冲刷时刻优先取本机偏好文件里的那一份，进程重启之后也按它判断。
  Future<void> flushIfDue({DateTime? now}) async {
    final at = now ?? clock();
    var last = _lastFlushAt;
    final stored = storedFlushAt;
    if (stored != null) {
      try {
        final saved = await stored();
        if (saved != null && (last == null || saved.isAfter(last))) {
          last = saved;
        }
      } catch (_) {
        // 读不到本机记下的时刻时按本次运行里的判断。
      }
    }
    if (last != null && at.difference(last) < flushInterval) return;
    await flush(now: at);
  }

  /// 把本设备还没数过的使用记录累进 `memory_usage`，形成一条维护提交。
  ///
  /// 没有可数的记录时不写库，也不形成提交；返回本次是否形成了提交。
  Future<bool> flush({DateTime? now}) async {
    if (_flushing) return false;
    _flushing = true;
    try {
      // 先排空写入队列：刚记下的使用也要进这一次现算。
      await _writes;
      final deviceId = await _accountDeviceId();
      if (deviceId == null) return false;
      final at = now ?? clock();
      final counts = await _countsAfter(deviceId);
      if (counts.isEmpty) {
        // 没有新的使用也要记住这次冲刷：距离超过一天才再来一次。
        await _rememberFlush(at);
        return false;
      }
      final stamp = formatDateTime(at);
      try {
        await transactions.run(
          (txn) async {
            await _apply(
              deviceId,
              counts,
              firstSeenAt: stamp,
              updatedAt: stamp,
              txn: txn,
            );
            return txn.result();
          },
          label: flushMemoryUsageAction,
          actor: 'system',
          kind: RevisionKind.maintenance,
        );
      } catch (_) {
        // 提交没有落库时不推进冲刷时刻，下一次进入后台再试。
        return false;
      }
      await _rememberFlush(at);
      final flushed = onFlushed;
      if (flushed != null) {
        try {
          await flushed();
        } catch (_) {
          // 统计已经落库；索引下次重建时会读到新的版本。
        }
      }
      return true;
    } finally {
      _flushing = false;
    }
  }

  /// 记下这次冲刷的时刻：本次运行与（可选的）本机偏好文件各记一份。
  Future<void> _rememberFlush(DateTime at) async {
    _lastFlushAt = at;
    final record = recordFlushAt;
    if (record == null) return;
    try {
      await record(at);
    } catch (_) {
      // 写不进偏好文件只影响下一次是否提前冲刷一次，不影响统计本身。
    }
  }

  /// 本设备 `acquired_at > first_seen_at` 的使用记录，按记忆编号分开现算。
  ///
  /// `first_seen_at` 取本设备该记忆的统计行；还没有行时按空串处理，这一批全部
  /// 计入。排序与去重都交给 SQL，读出之后只在内存里累加。
  Future<Map<String, _UsageCounts>> _countsAfter(String deviceId) async {
    final rows = await db.rawQuery(
      'SELECT u.memory_id AS memory_id, u.kind AS kind, u.used_at AS used_at '
      'FROM memory_use u '
      'LEFT JOIN memory_usage g ON g.memory_id = u.memory_id '
      '  AND g.device_id = u.device_id '
      'WHERE u.device_id = ? '
      "  AND (g.first_seen_at IS NULL OR u.acquired_at > g.first_seen_at)",
      [deviceId],
    );
    final counts = <String, _UsageCounts>{};
    for (final row in rows) {
      final memoryId = row['memory_id']! as String;
      final usedAt = row['used_at'] as String?;
      final entry = counts.putIfAbsent(memoryId, _UsageCounts.new);
      if (row['kind'] == MemoryUseKind.recall.value) {
        entry.recall += 1;
        entry.lastRecalledAt = _later(entry.lastRecalledAt, usedAt);
      } else {
        entry.search += 1;
        entry.lastSearchedAt = _later(entry.lastSearchedAt, usedAt);
      }
    }
    return counts;
  }

  static String? _later(String? current, String? candidate) {
    if (candidate == null || candidate.isEmpty) return current;
    if (current == null || candidate.compareTo(current) > 0) return candidate;
    return current;
  }

  /// 统计行的编号：记忆编号加设备编号定下来，各设备的行因此同名不冲突。
  static String _usageId(String deviceId, String memoryId) =>
      contentHash('memory-usage\n$deviceId\n$memoryId'.codeUnits);

  /// 在事务里累加计数、写回本设备的时间列，并删掉已经数过的旧使用记录。
  ///
  /// 计数由使用记录现算；记忆被删除时 `memory_use` 随外键一起删掉，不会留下
  /// 数不到的孤儿行。
  Future<void> _apply(
    String deviceId,
    Map<String, _UsageCounts> counts, {
    required String firstSeenAt,
    required String updatedAt,
    required WriteTransaction txn,
  }) async {
    for (final entry in counts.entries) {
      final memoryId = entry.key;
      final counted = entry.value;
      final existing = await txn.executor.selectGenerated(
        (db) => db.usageOf(memoryId, deviceId).getSingleOrNull(),
      );
      if (existing == null) {
        await txn.executor.writeGenerated(
          (db) => db.insertMemoryUsage(
            _usageId(deviceId, memoryId),
            memoryId,
            deviceId,
            counted.recall,
            counted.search,
            counted.lastRecalledAt,
            counted.lastSearchedAt,
            firstSeenAt,
            updatedAt,
          ),
        );
        continue;
      }
      await txn.executor.writeGenerated(
        (db) => db.updateMemoryUsage(
          existing.recallCount + counted.recall,
          existing.searchCount + counted.search,
          _later(existing.lastRecalledAt, counted.lastRecalledAt),
          _later(existing.lastSearchedAt, counted.lastSearchedAt),
          firstSeenAt,
          updatedAt,
          existing.id,
        ),
      );
    }
    await txn.executor.writeGenerated(
      (db) => db.deleteCountedMemoryUses(deviceId),
    );
  }

  /// 读本设备的统计行：记忆编号到计数、最近使用时间与首次看到的时间。
  ///
  /// 换库期间取不到 drift 主库时按没有统计处理，界面不因此报错。
  Future<Map<String, MemoryUsage>> readUsage() async {
    final connection = db.driftConnection;
    if (connection is! AppDatabase) return const {};
    final deviceId = await this.deviceId();
    final rows = await connection.usageForDevice(deviceId).get();
    return {
      for (final row in rows)
        row.memoryId: MemoryUsage(
          memoryId: row.memoryId,
          deviceId: row.deviceId,
          recallCount: row.recallCount,
          searchCount: row.searchCount,
          lastRecalledAt: optionalDateTime(row.lastRecalledAt ?? ''),
          lastSearchedAt: optionalDateTime(row.lastSearchedAt ?? ''),
          firstSeenAt: requiredDateTime(row.firstSeenAt),
          updatedAt: requiredDateTime(row.updatedAt),
        ),
    };
  }
}

/// 一条记忆在本机的使用统计。
class MemoryUsage {
  const MemoryUsage({
    required this.memoryId,
    required this.deviceId,
    required this.recallCount,
    required this.searchCount,
    required this.firstSeenAt,
    required this.updatedAt,
    this.lastRecalledAt,
    this.lastSearchedAt,
  });

  final String memoryId;
  final String deviceId;
  final int recallCount;
  final int searchCount;
  final DateTime? lastRecalledAt;
  final DateTime? lastSearchedAt;
  final DateTime firstSeenAt;
  final DateTime updatedAt;

  int get total => recallCount + searchCount;

  /// 最近一次使用的时间；从没被用过时为空。
  DateTime? get lastUsedAt {
    final recalled = lastRecalledAt;
    final searched = lastSearchedAt;
    if (recalled == null) return searched;
    if (searched == null) return recalled;
    return recalled.isAfter(searched) ? recalled : searched;
  }
}

/// 一次冲刷里一条记忆的现算结果。
class _UsageCounts {
  int recall = 0;
  int search = 0;
  String? lastRecalledAt;
  String? lastSearchedAt;
}
