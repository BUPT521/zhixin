import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../revisions/revision_engine.dart';
import 'drift/app_database.dart';
import 'drift/drift_raw.dart';
import 'raw_executor.dart';
import 'sql.dart';

/// 库文件与 schema 版本。库文件放在应用私有目录，导出时整份复制。
///
/// 30 之后的那一次变化把版本与同步的簿记收拢成一次：单行状态与 `HEAD` 合进
/// `revision_state`，完整性只留整库摘要，命名版本改按 `uid` 引用并随账号同步，
/// 记忆改三类标签并加使用统计（ADR-0051、0054，审查第 8 节）。
const String zhixinDbFileName = 'zhixin.db';
const int zhixinSchemaVersion = 31;

/// 与库文件同名的附属文件：回滚日志、WAL 与共享内存。
const List<String> zhixinDbSideFiles = ['-journal', '-wal', '-shm'];

/// 打开（必要时新建）本地库。
///
/// 表结构由 drift 的 [AppDatabase] 建立；版本与当前结构不一致时清空所有表
/// 并按当前结构重建：开发期只有可丢弃的测试数据，旧库整体重建，不进入升级
/// 路径（ADR-0002）。版本引擎初始化时安装版本采集触发器，并清理旧版关键词
/// 索引留下的派生表（ADR-0024）。
///
/// 底层 `sqlite3` 连接由这里持有、交给 [DriftRawDatabase] 关闭：drift 的关闭
/// 流程要经过几个微任务，页面退出与测试收尾时它们可能不再推进，而底层连接
/// 是同步关闭的，关掉它文件句柄就立刻归还（ADR-0014 实施时发现）。
Future<RawDatabase> openZhixinDatabase({
  required String path,
  Clock clock = systemClock,
}) async {
  final file = sqlite.sqlite3.open(path);
  final app = AppDatabase(
    NativeDatabase.opened(file, closeUnderlyingOnClose: false),
  );
  final raw = DriftRawDatabase(app, connection: file);
  // 触发一次查询，让 drift 完成建表与迁移。
  await raw.rawQuery('PRAGMA user_version');
  await RevisionEngine(clock: clock)
      .initialize(raw, seed: () => _seed(raw, zhixinSchemaVersion, clock));
  return raw;
}

Future<void> _seed(RawDatabase db, int version, Clock clock) async {
  final now = formatDateTime(clock());
  await insertRow(db, 'app_meta', {
    'key': 'schema_version',
    'value': '$version',
    'updated_at': now,
  }, replace: true);
}
