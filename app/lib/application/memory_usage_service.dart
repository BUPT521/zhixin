import 'dart:async';

import '../data/db/drift/app_database.dart';
import '../data/db/raw_executor.dart';
import '../data/db/write_transactions.dart';
import '../domain/rules/revision_actions.dart';
import '../domain/models/revision_models.dart';
import '../domain/models/memory.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import '../domain/rules/uuid_v5.dart';

/// 记忆的使用记录种类（01 `local_memory_use.kind`）：进入相关层、由
/// `search_memory` 读到。
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
/// 账号服务（例如登录凭据不可用）时才用这个标识，读统计时仍能定位到本机行。
const String localMemoryUsageDeviceId = 'local';

/// 记忆使用统计（ADR-0051 决定第 8 条，审查 S16）。
///
/// 召回进入相关层与被 `search_memory` 读到的次数先记在本机缓冲表
/// `local_memory_use`：每次使用只排一行写入，缓冲行按行号区分，所以同一秒的
/// 连续使用各记一行。表名带 `local_` 前缀、不参与版本采集，写缓冲因此不形成
/// 提交，也不推进 `HEAD`。
///
/// 冲刷时先排空写入队列，取账号设备编号，读出缓冲里未汇总的计数与最近时刻，
/// 在一条 `maintenance`、`system` 的提交里把计数累加进 `memory_usage`、更新
/// `last_recalled_at` 与 `last_searched_at`，并在同一个事务里清空缓冲；汇总与
/// 删除同事务完成，所以重复冲刷不会重复计数，也不需要水位列。
///
/// 冲刷只在应用进入后台、且距上次冲刷不少于 [flushInterval] 时进行，不另外
/// 触发同步。设备编号取 [deviceIdSource]（运行时是
/// `AccountService.deviceId()`）；取不到就跳过冲刷，因为 `memory_usage` 的行
/// 仍按设备记。
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

  /// 本次运行里记下、还没写进缓冲的次数，按记忆编号分开；用于观察与测试。
  final Map<String, int> _pendingRecalls = {};
  final Map<String, int> _pendingSearches = {};

  /// 写缓冲的队列：每次召回只排一行写入，输出按出现顺序，不在回答路上等。
  Future<void> _writes = Future<void>.value();

  String? _deviceId;
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
    // 缓冲行按行号区分，时刻不必错开；同一秒里连着记几次就是几行。
    final usedAt = formatDateTime(at ?? clock());
    _writes = _writes.then((_) => _writeUse(kind, memoryId, usedAt));
  }

  /// 往本机缓冲写一行使用记录；库暂时不可用时只丢这一行，不影响回答。
  ///
  /// 缓冲表属于 `local_` 前缀，不参与版本采集，所以这次写入不形成提交；也不
  /// 按设备或时刻算编号，行号由缓冲表自增给出。
  Future<void> _writeUse(
    MemoryUseKind kind,
    String memoryId,
    String usedAt,
  ) async {
    try {
      await db.transaction(
        (txn) => txn.selectGenerated(
          (db) => db.insertLocalMemoryUse(memoryId, kind.value, usedAt),
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

  /// 本机设备标识：优先用账号服务给的设备编号（未登录也有），取不到时退到
  /// 固定的本机标识，读统计时因此仍能定位到本机行。
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

  /// 只问账号服务，不回落本机标识：冲刷用它判断“取不到设备编号就跳过”。
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

  /// 把本机缓冲里还没汇总的使用累进 `memory_usage`，形成一条维护提交。
  ///
  /// 没有缓冲行时不写库，也不形成提交；返回本次是否形成了提交。
  Future<bool> flush({DateTime? now}) async {
    if (_flushing) return false;
    _flushing = true;
    try {
      // 先排空写入队列：刚记下的使用也要进这一次汇总。
      await _writes;
      final deviceId = await _accountDeviceId();
      if (deviceId == null) return false;
      final at = now ?? clock();
      final List<LocalUseCountsResult> buffered;
      try {
        buffered = await db.selectGenerated((db) => db.localUseCounts().get());
      } catch (_) {
        // 换库期间没有 drift 主库：这一次冲刷跳过，缓冲行留着下次再汇总。
        return false;
      }
      if (buffered.isEmpty) {
        // 没有新的使用也要记住这次冲刷：距离超过一天才再来一次。
        await _rememberFlush(at);
        return false;
      }
      final stamp = formatDateTime(at);
      final WriteResult result;
      try {
        result = await transactions.run(
          (txn) async {
            // 在事务里重新读一次：重读到的缓冲行与删除在同一次提交里完成。
            final counts = await txn.executor.selectGenerated(
              (db) => db.localUseCounts().get(),
            );
            if (counts.isNotEmpty) {
              await _apply(deviceId, counts, updatedAt: stamp, txn: txn);
            }
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
      if (!result.changed) return false;
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

  /// 统计行的编号：以“设备编号＋记忆编号”为名字生成 UUIDv5（ADR-0053 决定
  /// 第 4 条，审查 S17）。同一台设备同一条记忆永远是同一个编号，也不再是内容
  /// 哈希的形状。
  static String _usageId(String deviceId, String memoryId) =>
      uuidV5('$deviceId\n$memoryId');

  /// 在事务里累加计数、写回本设备的时间列，并清空本机缓冲。
  ///
  /// 缓冲行与统计行在同一事务里处理；记忆被硬删除时缓冲行随外键一起删掉，
  /// 不会留下数不到的孤儿行。
  Future<void> _apply(
    String deviceId,
    Iterable<LocalUseCountsResult> counts, {
    required String updatedAt,
    required WriteTransaction txn,
  }) async {
    // 缓冲按记忆与种类各一行，先按记忆合并成一行统计。
    final merged = <String, _UsageCounts>{};
    for (final row in counts) {
      final entry = merged.putIfAbsent(row.memoryId, _UsageCounts.new);
      if (row.kind == MemoryUseKind.recall.value) {
        entry.recall += row.useCount;
        entry.lastRecalledAt = _later(entry.lastRecalledAt, row.lastUsedAt);
      } else {
        entry.search += row.useCount;
        entry.lastSearchedAt = _later(entry.lastSearchedAt, row.lastUsedAt);
      }
    }
    for (final entry in merged.entries) {
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
          updatedAt,
          existing.id,
        ),
      );
    }
    await txn.executor.writeGenerated((db) => db.deleteLocalMemoryUses());
  }

  /// 两个时刻文本里较晚的一个；空值表示还没有时刻。
  static String? _later(String? current, String? candidate) {
    if (candidate == null || candidate.isEmpty) return current;
    if (current == null || candidate.compareTo(current) > 0) return candidate;
    return current;
  }

  /// 读本设备的统计行：记忆编号到计数与最近使用时间。
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
