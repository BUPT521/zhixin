import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/cloud/cloud_preferences_store.dart';
import '../data/cloud/server_client.dart';
import '../data/db/app_database.dart' show zhixinSchemaVersion;
import '../data/db/guarded_database.dart';
import '../data/db/sql.dart';
import '../data/db/write_transactions.dart';
import '../data/revisions/asset_store.dart';
import '../data/revisions/revision_cursor.dart';
import '../data/revisions/revision_digest.dart';
import '../data/revisions/revision_engine.dart';
import '../data/revisions/revision_models.dart';
import '../data/revisions/revision_service.dart';
import '../data/revisions/revision_shadow.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import 'account_service.dart';

/// 服务端接受的客户端 schema 与本机不一致：两端要一起升级。
class SyncSchemaMismatch implements Exception {
  const SyncSchemaMismatch({required this.server, required this.client});

  final int server;
  final int client;

  @override
  String toString() => '服务端接受 schema $server，本机是 $client；升级应用或服务端后再同步';
}

/// 同步途中切换了服务实例或账号：这次同步的结果属于旧身份，直接丢弃。
class SyncIdentityChanged implements Exception {
  const SyncIdentityChanged();

  @override
  String toString() => '账号或服务实例已经变化，这次同步没有完成';
}

/// 这个账号还没有同步过：首次同步要先由用户确认；整库恢复之后的第一轮同步
/// 同样要确认，但云端会改成恢复后的内容。
class BaselineConfirmationRequired implements Exception {
  const BaselineConfirmationRequired(
    this.localCommits, {
    this.afterRestore = false,
  });

  /// 本机当前 HEAD 对应的提交数，用来告诉用户本机有多少记录。
  ///
  /// 首次同步不再把这些提交整份上传：确认之后只上传本机独有、云端还没有的行，
  /// 这个数字只用于界面说明本机已有的历史（同步方案 3.6）。
  final int localCommits;

  /// 整库恢复之后的第一轮同步：确认之后不是整份上传本机记录，而是把恢复这一步
  /// 的差异推上去，云端会改成恢复后的内容（同步方案 3.4）。
  final bool afterRestore;

  String get message => afterRestore
      ? '本机刚刚恢复过一份旧备份。继续之后会把恢复后的内容同步到云端，'
            '恢复之前推送的多余记录会从云端删除，其他登录这个账号的设备也会看到恢复后的内容。'
      : '这个账号还没有同步过。继续之后会先拉取云端已有的记录，只把本机独有、'
            '云端没有的记录上传作为基线，其他登录这个账号的设备也会看到这些记录。';

  @override
  String toString() => message;
}

/// 同步位置归属的 scope：账号编号与实例来源的 SHA-256 前 32 位。
///
/// 库里的两个同步位置（推送与服务端）都写这个值。退出登录、删除账号与清除
/// 云端只把位置改成不阻塞、位置与 scope 保留；重新登录同一 scope 时从原位置
/// 继续增量同步，scope 不同才按新账号处理（同步方案 3.3）。
String syncScopeFor(String userId, String origin) =>
    sha256.convert(utf8.encode('$userId|$origin')).toString().substring(0, 32);

/// 增量同步一屏读到的状态，设置页与账号页据此显示登录、待推送与上次同步。
class SyncStatus {
  const SyncStatus({
    required this.signedIn,
    required this.accountLabel,
    required this.autoSync,
    required this.syncing,
    required this.pendingCommits,
    required this.localHead,
    required this.serverHead,
    required this.needsBootstrap,
    this.baselineNeedsConfirmation = false,
    this.restoreNeedsConfirmation = false,
    this.digestMismatch = false,
    this.lastSyncedAt,
    this.lastError,
  });

  final bool signedIn;

  /// 账号页显示的一行：第一条登录方式的值；资料还没读到时为空。
  final String accountLabel;
  final bool autoSync;
  final bool syncing;
  final int pendingCommits;
  final int localHead;
  final int? serverHead;
  final bool needsBootstrap;

  /// 首次基线上传还没得到用户确认；界面据此在同步前询问一次。
  final bool baselineNeedsConfirmation;

  /// 整库恢复之后还没重新对齐：界面据此说明“云端会改成恢复后的内容”，
  /// 并在同步前询问一次（同步方案 3.4）。
  final bool restoreNeedsConfirmation;

  /// 上次同步比较摘要时发现本机与云端不一致（同步方案 3.5）：账号页据此
  /// 显示“本机与云端不一致”与两个修复入口，不阻塞同步本身。
  final bool digestMismatch;
  final DateTime? lastSyncedAt;
  final String? lastError;
}

/// 一次同步的结果：拉取与推送的提交数、上传与下载的附件数。
class SyncResult {
  const SyncResult({
    this.pulledCommits = 0,
    this.pushedCommits = 0,
    this.uploadedAssets = 0,
    this.downloadedAssets = 0,
  });

  final int pulledCommits;
  final int pushedCommits;
  final int uploadedAssets;
  final int downloadedAssets;

  bool get changed =>
      pulledCommits > 0 ||
      pushedCommits > 0 ||
      uploadedAssets > 0 ||
      downloadedAssets > 0;
}

/// 按提交序列与服务端同步：首次同步先把远端提交全部拉下来，只把本机独有、
/// 云端还没有的行作为基线上传（同步方案 3.6，相当于 git 的 clone）；之后拉取
/// 远端提交、在本机应用为新的提交，再推送本机新提交，并把提交里引用的附件按
/// 哈希补齐。
///
/// 库里的两个同步位置带一个 `scope`（账号编号与实例来源的哈希）：退出登录、
/// 删除账号与清除云端只把推送位置改成不阻塞、位置与 `scope` 保留，重新登录
/// 同一 scope 时从原位置继续增量同步（同步方案 3.3）。
///
/// 整库恢复之后的第一轮同步不拉取：恢复前的库作为恢复点已经存在，恢复后的库
/// 里补记了一条 `restore` 提交（差异含删除），用户确认“云端会改成恢复后的
/// 内容”之后只把这条差异推上去，两个位置收敛到当前服务端位置与本机 `HEAD`
/// （同步方案 3.4）。
///
/// 服务端只保存线性序列，不解析内容；冲突按“后到达的覆盖先到达的”处理，被覆盖
/// 的值留在提交历史里（[server/README](../../../server/README.md) 的同步协议）。
/// 同步只读写本机数据库与网络，不换库、不清空，界面通过数据层已有的表通知重读。
///
/// 拉取之后推送相当于 git 的 `pull --rebase`，粒度是格子：被远端提交取代的本机
/// 格子登记在库里的 `sync_shadow`，推送时去掉这些格子再推，剩余为空的提交不推
/// 但位置照常前进（ADR-0040）。
///
/// 推送给服务端的 `request_id` 填提交的 uid：服务端仍按这个字段跳过已经收到过的
/// 提交，但它现在标识一条提交，不再按命令参数生成，也不再复用（ADR-0040）。
class SyncService {
  SyncService({
    required this.account,
    required this.preferences,
    required this.revisions,
    required this.engine,
    required this.database,
    required this.transactions,
    required this.assets,
    required this.cache,
    required this.clock,
    required this.recordFailure,
  });

  final AccountService account;
  final CloudPreferencesStore preferences;
  final RevisionService revisions;
  final RevisionEngine engine;
  final GuardedDatabase database;
  final WriteTransactions transactions;
  final AssetStore assets;
  final AttachmentCache cache;
  final Clock clock;
  final void Function(Object error, StackTrace stack, {required String kind})
  recordFailure;

  /// 一批最多推送的提交数，与契约的 `maxItems: 200` 一致。
  static const int _pushBatch = 200;

  /// 首次基线一条提交最多带的变化数：控制单次请求体大小，避免超过服务端上限。
  static const int _baselineChunk = 100;
  static const int _pushBytes = (16 << 20) - 1024;
  static const int _commitBytes = (2 << 20) - 512;

  Future<SyncResult>? _running;
  Timer? _timer;
  String? _lastError;

  bool _disposed = false;

  /// 这次同步开始时的身份代次；切换账号或实例之后进行中的同步据此丢弃结果。
  int? _runEpoch;

  /// 这次同步的同步位置 scope；两个位置写入时都带上它（同步方案 3.3）。
  String? _activeScope;

  /// 这次同步里应用远端提交时被跳过的变化条数。
  ///
  /// 有跳过说明本机状态与云端对不上（例如本机删掉了远端还要修改的行），这时
  /// 推送即使成功也不代表云端会等于本机，最后一条提交不能带摘要（同步方案 3.5）。
  int _pulledSkipped = 0;

  /// 这次同步开始时已经知道本机与云端不一致。
  ///
  /// 已知不一致时推送只补本机内容，删不掉云端多出来的行，不能对外声明“推完之
  /// 后云端就等于本机”；摘要因此等到比较确认一致、或者用户做了一次修复之后再
  /// 带（同步方案 3.5）。
  bool _knownDigestMismatch = false;

  bool get syncing => _running != null;

  /// 已被远端提交取代的本机格子：拉取时由版本引擎在应用远端提交的事务里登记，
  /// 推送时按格去掉，作用相当于 git 的 `pull --rebase`（ADR-0040）。
  RevisionShadows get _shadows => RevisionShadows(database.raw);

  /// 同步位置：推送读到哪里与服务端拉到哪个位置，都存在库里的
  /// `revision_cursor` 表，随整库恢复一起回去（ADR-0039）。
  RevisionCursors get _cursors => RevisionCursors(database.raw, clock: clock);

  Future<int> _pushedPosition() => _cursors.position(RevisionCursor.syncPushed);

  Future<int> _serverHeadPosition() =>
      _cursors.position(RevisionCursor.syncServerHead);

  /// 记下服务端拉到哪个位置；这个读者不阻塞裁剪。
  Future<void> _saveServerHead(int position) => _cursors.set(
    RevisionCursor.syncServerHead,
    position,
    blocking: false,
    scope: _activeScope,
  );

  /// 记下本机已经推送到哪里；推送会丢数据，落后的位置阻止裁剪与清理历史。
  Future<void> _savePushed(int position) => _cursors.set(
    RevisionCursor.syncPushed,
    position,
    blocking: true,
    scope: _activeScope,
  );

  /// 账号与实例是否还是这份同步状态对应的那一个；换过之后旧状态不能用。
  bool _sameIdentity(SyncState? state, String userId, String origin) =>
      state != null && state.userId == userId && state.serverOrigin == origin;

  /// 库里的同步位置是不是属于当前身份。
  ///
  /// 位置带着 scope 时按它判断，重新登录同一账号仍然算同一个身份，从原位置
  /// 继续增量同步（同步方案 3.3）；scope 是这次改动新加的，旧库里同一账号的
  /// 位置没有 scope，这时以偏好文件里的同步状态为准。
  bool _positionLinked(
    RevisionCursor? pushed,
    String scope,
    SyncState? identityState,
  ) {
    if (pushed == null) return false;
    final cursorScope = pushed.scope;
    return cursorScope == null ? identityState != null : cursorScope == scope;
  }

  /// 身份在同步途中变化时抛出 [SyncIdentityChanged]，不再写回旧账号的游标。
  void _ensureIdentity() {
    final expected = _runEpoch;
    if (expected != null && account.identityEpoch != expected) {
      throw const SyncIdentityChanged();
    }
  }

  Future<SyncStatus> status() async {
    final snapshot = await account.snapshot();
    final localHead = await engine.headId(database.raw);
    final state = await preferences.syncState();
    if (!snapshot.signedIn) {
      return SyncStatus(
        signedIn: false,
        accountLabel: '',
        autoSync: snapshot.autoSync,
        syncing: syncing,
        pendingCommits: 0,
        localHead: localHead,
        serverHead: null,
        needsBootstrap: false,
        lastError: _lastError,
      );
    }
    final userId = snapshot.session!.userId;
    final origin = await account.serverOrigin();
    final scope = syncScopeFor(userId, origin);
    final identityState = _sameIdentity(state, userId, origin) ? state : null;
    final pushed = await _cursors.read(RevisionCursor.syncPushed);
    if (!_positionLinked(pushed, scope, identityState)) {
      // 这个身份还没有库里的同步位置（或者位置属于别的账号与实例）：下一轮
      // 同步会先拉取云端已有的记录，再把本机独有的行作为基线上传（同步方案
      // 3.6）。
      return SyncStatus(
        signedIn: true,
        accountLabel: snapshot.displayLabel,
        autoSync: snapshot.autoSync,
        syncing: syncing,
        pendingCommits: localHead,
        localHead: localHead,
        serverHead: null,
        needsBootstrap: true,
        baselineNeedsConfirmation: localHead > 0,
        digestMismatch: identityState?.digestMismatch ?? false,
        lastError: _lastError,
      );
    }
    final alignment = await _cursors.read(RevisionCursor.syncRestoreAlign);
    return SyncStatus(
      signedIn: true,
      accountLabel: snapshot.displayLabel,
      autoSync: snapshot.autoSync,
      syncing: syncing,
      pendingCommits: (await revisions.commitsAfter(pushed?.position ?? 0))
          .length,
      localHead: localHead,
      serverHead: await _serverHeadPosition(),
      needsBootstrap: false,
      restoreNeedsConfirmation: alignment != null,
      digestMismatch: identityState?.digestMismatch ?? false,
      lastSyncedAt: identityState?.syncedAt,
      lastError: _lastError,
    );
  }

  /// 立即同步；同时只跑一次，重复调用等同一个结果。
  ///
  /// [confirmBaseline] 表示用户已经在界面上确认过首次基线上传；没有确认时
  /// 遇到需要上传本机记录的情况会抛出 [BaselineConfirmationRequired]。
  Future<SyncResult> syncNow({bool confirmBaseline = false}) {
    final running = _running;
    if (running != null) return running;
    final future = _sync(confirmBaseline: confirmBaseline);
    _running = future.whenComplete(() => _running = null);
    return _running!;
  }

  /// 写入、登录与应用启动之后延迟同步一次：连续写入只排一次，失败只留说明。
  ///
  /// 首次基线上传需要用户确认，没有确认之前不自动上传，也不反复重试；账号页
  /// 的“立即同步”会先问一次。整库恢复之后同样先不自动同步：下一轮同步要
  /// 用户确认“云端会改成恢复后的内容”（同步方案 3.4）。
  Future<void> schedule({Duration delay = const Duration(seconds: 5)}) async {
    if (_disposed) return;
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn || !snapshot.autoSync) return;
    final origin = await account.serverOrigin();
    final state = await preferences.syncState();
    final identityState = _sameIdentity(state, snapshot.session!.userId, origin)
        ? state
        : null;
    final scope = syncScopeFor(snapshot.session!.userId, origin);
    final pushed = await _cursors.read(RevisionCursor.syncPushed);
    if (!_positionLinked(pushed, scope, identityState) &&
        await engine.headId(database.raw) > 0) {
      return;
    }
    if (await _cursors.read(RevisionCursor.syncRestoreAlign) != null) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      if (_disposed) return;
      unawaited(
        syncNow().catchError((Object error, StackTrace stack) {
          _lastError = _describe(error);
          return const SyncResult();
        }),
      );
    });
  }

  /// 退出登录、删除账号或清除云端数据之后清掉账号的同步状态。
  ///
  /// 库里的同步位置默认不删，只把推送位置改成不阻塞：退出之后“清理历史”立即
  /// 可用，位置与 scope 留着，重新登录同一账号时从原位置继续增量同步，而不是
  /// 按首次基线整份重传（同步方案 3.3）。
  ///
  /// [forgetPosition] 为真时连两个位置与恢复标记一起删掉（清除云端数据之后
  /// 云端序列已经空了，旧位置不再有意义），下一次同步按首次基线重新建立。
  Future<void> clearState({bool forgetPosition = false}) async {
    await preferences.clearSyncState();
    if (!forgetPosition) {
      await releaseSyncCursor();
      return;
    }
    try {
      await _forgetSyncPosition();
    } catch (error, stack) {
      recordFailure(error, stack, kind: 'sync_cursor_forget');
    }
  }

  /// 把库里的推送位置改成不阻塞，位置与 scope 保留。
  ///
  /// 账号服务在退出登录、删除账号、清除云端与重设密码之后调用；会丢数据的
  /// 读者不再挡住清理历史，位置仍然可以继续用。库还没打开等情况下失败只记
  /// 诊断，不影响账号操作本身。
  Future<void> releaseSyncCursor() async {
    try {
      await _cursors.release(RevisionCursor.syncPushed);
    } catch (error, stack) {
      recordFailure(error, stack, kind: 'sync_cursor_release');
    }
  }

  /// “以云端为准修复”：按云端的提交序列重放出一份投影，把本机被改动、与云端
  /// 不同的行改成云端值，再把本机独有的行作为基线上传（同步方案 3.5）。
  ///
  /// 3.7 的客户端快照克隆还没有落地。这里不直接清掉位置重拉：本机已经应用过的
  /// 远端提交按 uid 去重，重新拉取不会再写一遍，漏掉的内容不会自己回来。于是按
  /// 方案里“按差异重放”的退路实现：从服务端第 1 条开始只读地重放全部提交，得到
  /// 云端投影与云端碰过的行；这些行在本机与云端不同的改写成云端值并形成一条本机
  /// 提交（它的内容云端已经有了，所以随后把推送位置一起推进，不再推上去），没有
  /// 被云端碰过的本机行照旧作为基线补传。调用方必须先让用户确认。成功之后清掉
  /// 不一致标记。
  Future<SyncResult> repairFromCloud() async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) throw const AccountSignedOut();
    await _waitForRunningSync();
    final deviceId = await account.deviceId();
    final epoch = account.identityEpoch;
    final origin = await account.serverOrigin();
    _runEpoch = epoch;
    _pulledSkipped = 0;
    _knownDigestMismatch = false;
    try {
      final userId = snapshot.session!.userId;
      _activeScope = syncScopeFor(userId, origin);
      // 先清掉两个同步位置与遮蔽行：这次修复不从旧位置接着增量，而是按服务端
      // 序列重新对齐一遍，收尾时再写回新的位置。
      await _forgetSyncPosition();
      final cloud = <String, Map<String, TypedRow>>{};
      final touched = <(String, String)>{};
      var serverHead = 0;
      var pulled = 0;
      while (true) {
        _ensureIdentity();
        final page = await account.call(
          (client, token) => client.pull(token, after: serverHead),
        );
        if (page.commits.isEmpty) {
          // 再读一页确认真实的位置：修复期间另一台设备也可能在推，按最后一页
          // 的 head 推送基线才不会撞上 409。
          serverHead = page.head;
          break;
        }
        for (final commit in page.commits) {
          for (final change in commit.changes) {
            touched.add((change.table, change.rowKey));
            final rows = cloud.putIfAbsent(change.table, () => {});
            if (change.op == 'delete') {
              rows.remove(change.rowKey);
              continue;
            }
            final after = decodeTypedRow(jsonEncode(change.after));
            if (change.op == 'insert') {
              rows[change.rowKey] = after;
            } else {
              // 更新只带变化列，重放时要并进上一条提交留下的整行。
              rows[change.rowKey] = {...?rows[change.rowKey], ...after};
            }
          }
        }
        pulled += page.commits.length;
        serverHead = page.commits.last.seq ?? serverHead;
      }
      // 云端碰过的行按云端值改写，没有被云端碰过的本机行保留下来补传。
      final local = await engine.readProjection(database.raw);
      await database.command((txn) async {
        for (final key in touched) {
          final table = key.$1;
          final rowKey = key.$2;
          final primaryKey = versionedPrimaryKeys[table];
          if (primaryKey == null) continue;
          final target = cloud[table]?[rowKey];
          final current = local[table]?[rowKey];
          if (target == null) {
            if (current == null) continue;
            await deleteRows(
              txn,
              table,
              where: '$primaryKey = ?',
              whereArgs: [rowKey],
            );
            continue;
          }
          if (current == null) {
            await insertRow(txn, table, {
              primaryKey: rowKey,
              ...sqliteRow(target),
            });
            continue;
          }
          if (canonicalRevisionRow(table, rowKey, target) ==
              canonicalRevisionRow(table, rowKey, current)) {
            continue;
          }
          final update = <String, Object?>{};
          for (final entry in target.entries) {
            if (entry.key == primaryKey) continue;
            final before = current[entry.key];
            if (before != null &&
                jsonEncode(before.toJson()) ==
                    jsonEncode(entry.value.toJson())) {
              continue;
            }
            update[entry.key] = entry.value.sqliteValue;
          }
          if (update.isEmpty) continue;
          await updateRow(
            txn,
            table,
            update,
            where: '$primaryKey = ?',
            whereArgs: [rowKey],
          );
        }
      }, label: '以云端为准重新对齐');
      // 重新对齐之后本机没有待推送提交：对齐提交的内容云端已经有了，推送位置
      // 直接推进到当前 HEAD；云端没有行的本机独有行照常作为基线补传。
      final headAfterAlign = await engine.headId(database.raw);
      final projection = await engine.readProjection(database.raw);
      final changes = <RevisionChange>[];
      var seq = 1;
      for (final table in versionedTableNames) {
        final rows = projection[table] ?? const <String, TypedRow>{};
        for (final entry in rows.entries) {
          if (touched.contains((table, entry.key))) continue;
          changes.add(
            RevisionChange(
              commitId: 0,
              seq: seq++,
              table: table,
              rowKey: entry.key,
              op: ChangeOp.insert,
              after: entry.value,
            ),
          );
        }
      }
      var pushed = 0;
      var baseSeq = serverHead;
      String? baselineDigest;
      if (changes.isNotEmpty) {
        final headBefore = await engine.headId(database.raw);
        final digest = await revisions.currentStateDigest();
        if (await engine.headId(database.raw) == headBefore) {
          baselineDigest = digest;
        }
      }
      await _pushBatches(
        Stream.fromIterable(
          _baselineCommits(deviceId, changes, stateDigest: baselineDigest),
        ),
        baseSeq,
        (head, count) async {
          baseSeq = head;
          pushed += count;
        },
      );
      final uploaded = await _uploadAssets(AssetStore.hashesInChanges(changes));
      _ensureIdentity();
      await _saveServerHead(baseSeq);
      await _savePushed(headAfterAlign);
      await _shadows.clear();
      await _saveDigestMismatch(false);
      await _markSynced();
      return SyncResult(
        pulledCommits: pulled,
        pushedCommits: pushed,
        uploadedAssets: uploaded,
      );
    } catch (error, stack) {
      if (error is! SyncIdentityChanged) {
        recordFailure(error, stack, kind: 'cloud_sync');
      }
      rethrow;
    } finally {
      _runEpoch = null;
      _activeScope = null;
    }
  }

  /// “以本机为准修复”：把本机独有的行按首次基线的方式推上去（同步方案 3.5、
  /// 3.6）。
  ///
  /// 先增量拉取云端的新提交，据此知道哪些“表名 + 主键”已经由远端提交表达过，
  /// 这些行在本机的副本不再上传；其余行作为基线提交推送，所以它只补云端缺的
  /// 内容，不删除云端已有的行。已经收到过的远端提交照常在本机应用，本机被直接
  /// 改过、没有提交记录表达的行由基线补上去。成功后且有内容上传时清掉不一致
  /// 标记；一行都没传说明两边只差在云端多出来的内容，标记留着等下一次同步重新
  /// 判断。账号还没有同步位置时按首次基线重新对齐一次。
  Future<SyncResult> repairFromLocal() async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) throw const AccountSignedOut();
    await _waitForRunningSync();
    final deviceId = await account.deviceId();
    final epoch = account.identityEpoch;
    final origin = await account.serverOrigin();
    _runEpoch = epoch;
    _pulledSkipped = 0;
    _knownDigestMismatch = false;
    try {
      final userId = snapshot.session!.userId;
      final scope = syncScopeFor(userId, origin);
      _activeScope = scope;
      final pushedCursor = await _cursors.read(RevisionCursor.syncPushed);
      final identityState = await preferences.syncState();
      if (!_positionLinked(
        pushedCursor,
        scope,
        identityState != null && _sameIdentity(identityState, userId, origin)
            ? identityState
            : null,
      )) {
        // 还没有同步位置（这个账号第一次同步）：按首次基线重新对齐，确认之后
        // 上传本机独有的行，与“立即同步”的第一步相同。
        final result = await syncNow(confirmBaseline: true);
        await _saveDigestMismatch(false);
        return result;
      }
      var serverHead = await _serverHeadPosition();
      // 按首次同步的做法从第 1 条开始读一遍服务端序列，只记录被提交碰过的行；
      // 已经应用过的远端提交按 uid 去重，不会重写本机内容。云端历史被压缩过时
      // 读不到更早的提交，退回按本机已有的远端提交判断，再从当前位置增量拉取。
      final pushedRows = <(String, String)>{};
      var pulled = 0;
      try {
        final result = await _pull(
          serverHead: 0,
          deviceId: deviceId,
          persist: false,
          downloaded: (count) {},
          touchedRows: pushedRows,
        );
        serverHead = result.serverHead;
        pulled = result.pulled;
      } on ServerProblem catch (error) {
        if (error.code != 'history_compacted') rethrow;
        pushedRows.addAll(await _remoteTouchedRows());
        final result = await _pull(
          serverHead: serverHead,
          deviceId: deviceId,
          downloaded: (count) {},
        );
        serverHead = result.serverHead;
        pulled = result.pulled;
      }
      final localHead = await engine.headId(database.raw);
      final projection = await engine.readProjection(database.raw);
      final changes = <RevisionChange>[];
      var seq = 1;
      for (final table in versionedTableNames) {
        final rows = projection[table] ?? const <String, TypedRow>{};
        for (final entry in rows.entries) {
          if (pushedRows.contains((table, entry.key))) continue;
          changes.add(
            RevisionChange(
              commitId: 0,
              seq: seq++,
              table: table,
              rowKey: entry.key,
              op: ChangeOp.insert,
              after: entry.value,
            ),
          );
        }
      }
      var pushed = 0;
      var baseSeq = serverHead;
      String? baselineDigest;
      if (changes.isNotEmpty && _pulledSkipped == 0) {
        final headBefore = await engine.headId(database.raw);
        final digest = await revisions.currentStateDigest();
        if (await engine.headId(database.raw) == headBefore) {
          baselineDigest = digest;
        }
      }
      await _pushBatches(
        Stream.fromIterable(
          _baselineCommits(deviceId, changes, stateDigest: baselineDigest),
        ),
        baseSeq,
        (head, count) async {
          baseSeq = head;
          pushed += count;
        },
      );
      final uploaded = await _uploadAssets(AssetStore.hashesInChanges(changes));
      _ensureIdentity();
      await _saveServerHead(baseSeq);
      await _savePushed(localHead);
      await _shadows.deleteSettled(localHead);
      if (changes.isNotEmpty) await _saveDigestMismatch(false);
      await _markSynced();
      return SyncResult(
        pulledCommits: pulled,
        pushedCommits: pushed,
        uploadedAssets: uploaded,
      );
    } catch (error, stack) {
      if (error is! SyncIdentityChanged) {
        recordFailure(error, stack, kind: 'cloud_sync');
      }
      rethrow;
    } finally {
      _runEpoch = null;
      _activeScope = null;
    }
  }

  /// 正在同步时等它结束再修复：两轮同时改同步位置会把位置写乱。
  ///
  /// 前一轮失败不影响这次修复，失败说明只在那个调用方处理。
  Future<void> _waitForRunningSync() async {
    final running = _running;
    if (running == null) return;
    try {
      await running;
    } catch (_) {
      // 前一轮的结果已经不相关，这次修复按当前库重新做。
    }
  }

  /// 本机历史里被远端提交碰过的“表名 + 主键”。
  ///
  /// 服务端序列里的每一行都来自某条远端提交，所以这些行在本机的副本不该再进
  /// 基线；“以本机为准修复”据此只推本机独有的行（同步方案 3.6）。
  Future<Set<(String, String)>> _remoteTouchedRows() async {
    final rows = await database.raw.rawQuery(
      'SELECT DISTINCT c.table_name AS table_name, c.row_key AS row_key '
      'FROM revision_change c '
      'JOIN revision_commit m ON m.id = c.commit_id '
      "WHERE m.kind = 'remote'",
    );
    return {
      for (final row in rows)
        (row['table_name']! as String, row['row_key']! as String),
    };
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<SyncResult> _sync({bool confirmBaseline = false}) async {
    _lastError = null;
    var pulled = 0;
    var pushed = 0;
    var uploaded = 0;
    var downloaded = 0;
    final deviceId = await account.deviceId();
    final epoch = account.identityEpoch;
    final origin = await account.serverOrigin();
    _runEpoch = epoch;
    _pulledSkipped = 0;
    try {
      final snapshot = await account.snapshot();
      if (!snapshot.signedIn) throw const AccountSignedOut();
      final remoteHead = await account.call(
        (client, token) => client.head(token),
      );
      if (remoteHead.schemaVersion != zhixinSchemaVersion) {
        throw SyncSchemaMismatch(
          server: remoteHead.schemaVersion,
          client: zhixinSchemaVersion,
        );
      }
      final userId = snapshot.session!.userId;
      final scope = syncScopeFor(userId, origin);
      _activeScope = scope;
      final localHead = await engine.headId(database.raw);
      var state = await preferences.syncState();
      if (state != null && !_sameIdentity(state, userId, origin)) {
        // 换了账号或实例：旧状态不再对应这个身份。
        await preferences.clearSyncState();
        state = null;
      }
      // 已知不一致时这一轮推送不挂摘要：推送只补本机内容，删不掉云端多出来的
      // 行，不能声明推完之后云端就等于本机。
      _knownDigestMismatch = state?.digestMismatch ?? false;
      final pushedCursor = await _cursors.read(RevisionCursor.syncPushed);
      // 位置属于当前身份才继续增量同步：退出登录只把位置改成不阻塞，scope 还在，
      // 重新登录同一账号因此仍从原位置继续（同步方案 3.3）。
      var linked = _positionLinked(pushedCursor, scope, state);
      var serverHead = linked ? await _serverHeadPosition() : 0;
      var pushedThrough = linked ? await _pushedPosition() : 0;
      var alignment = linked
          ? await _cursors.read(RevisionCursor.syncRestoreAlign)
          : null;
      if (linked && remoteHead.head < serverHead) {
        // 服务端序列被清空过，旧位置回到 0，需要重新上传基线；位置在首次
        // 同步收尾时随基线一起重写。
        await _forgetSyncPosition();
        linked = false;
        serverHead = 0;
        pushedThrough = 0;
        alignment = null;
      }
      var restoreFallback = false;
      if (alignment != null && alignment.position < 0) {
        // 恢复点读不出来或者补记失败：按首次基线重新对齐，同样先跳过旧位置。
        await _forgetSyncPosition();
        linked = false;
        alignment = null;
        restoreFallback = true;
      }

      if (linked && alignment != null) {
        // 整库恢复之后的第一轮同步：不拉取旧位置之后的提交，确认之后只把恢复
        // 这一步的差异推上去，两个位置收敛到当前服务端位置与本机 HEAD。
        if (!confirmBaseline) {
          throw BaselineConfirmationRequired(localHead, afterRestore: true);
        }
        final realigned = await _realignAfterRestore(
          remoteHead: remoteHead.head,
          deviceId: deviceId,
          uploaded: (count) => uploaded += count,
        );
        pushed += realigned.pushed;
        serverHead = realigned.serverHead;
        state = SyncState(userId: userId, serverOrigin: origin);
      } else if (!linked) {
        // 首次同步（或恢复之后按首次基线重新对齐）会先拉取云端已有的记录，
        // 再把本机独有、云端没有的行作为基线上传；本机没有记录时不会上传任何
        // 东西，也就不需要确认（同步方案 3.6）。
        await _clearRestoreMarker();
        if (localHead > 0 && !confirmBaseline) {
          throw BaselineConfirmationRequired(
            localHead,
            afterRestore: restoreFallback,
          );
        }
        final boot = await _bootstrap(deviceId);
        pulled += boot.pulled;
        pushed += boot.pushed;
        uploaded += boot.uploaded;
        downloaded += boot.downloaded;
        serverHead = boot.serverHead;
        state = SyncState(userId: userId, serverOrigin: origin);
      } else {
        final current = await _pull(
          serverHead: serverHead,
          deviceId: deviceId,
          downloaded: (count) => downloaded += count,
        );
        pulled += current.pulled;
        serverHead = current.serverHead;
        final push = await _push(
          serverHead: serverHead,
          pushedThrough: pushedThrough,
          deviceId: deviceId,
          uploaded: (count) => uploaded += count,
          onPulled: (result) {
            pulled += result.pulled;
            downloaded += result.downloaded;
          },
        );
        pushed += push.pushed;
        serverHead = push.serverHead;
        state = state ?? SyncState(userId: userId, serverOrigin: origin);
      }
      _ensureIdentity();
      // 收尾只更新“上次同步时间”。摘要比较与修复可能在这之前改过不一致标记，
      // 所以从偏好文件重读一次，不拿这次同步开头读到的那份覆盖它。
      final stored = await preferences.syncState();
      final base = stored != null && _sameIdentity(stored, userId, origin)
          ? stored
          : state;
      final finalState = base.copyWith(syncedAt: clock());
      await preferences.saveSyncState(finalState);
      return SyncResult(
        pulledCommits: pulled,
        pushedCommits: pushed,
        uploadedAssets: uploaded,
        downloadedAssets: downloaded,
      );
    } catch (error, stack) {
      _lastError = _describe(error);
      if (error is! SyncIdentityChanged &&
          error is! BaselineConfirmationRequired) {
        recordFailure(error, stack, kind: 'cloud_sync');
      }
      rethrow;
    } finally {
      _runEpoch = null;
      _activeScope = null;
    }
  }

  /// 整库恢复之后的重新对齐：跳过拉取，把恢复这一步的差异推到云端。
  ///
  /// 待推送的提交从恢复提交的父提交开始（恢复前后没有差异时从本机 `HEAD`
  /// 开始），所以推送的正是“恢复点投影 → 恢复后投影”的净变化，删除也会带上；
  /// 推送位置越过之后两个位置收敛到当前服务端位置与本机 `HEAD`，恢复之前的
  /// 改动不会再从旧位置拉回来（同步方案 3.4）。
  Future<({int serverHead, int pushed})> _realignAfterRestore({
    required int remoteHead,
    required String deviceId,
    required void Function(int count) uploaded,
  }) async {
    final push = await _push(
      serverHead: remoteHead,
      pushedThrough: await _pushedPosition(),
      deviceId: deviceId,
      uploaded: uploaded,
      onPulled: (_) {},
      pullBefore: false,
    );
    await _clearRestoreMarker();
    return (serverHead: push.serverHead, pushed: push.pushed);
  }

  /// 服务端序列被清空、或者恢复的备份对不上当前身份：两个同步位置与恢复标记
  /// 一起删掉，遮蔽行清空，回到按首次基线重建。
  Future<void> _forgetSyncPosition() async {
    await _cursors.delete(RevisionCursor.syncPushed);
    await _cursors.delete(RevisionCursor.syncServerHead);
    await _cursors.delete(RevisionCursor.syncRestoreAlign);
    await _shadows.clear();
  }

  /// 清掉恢复之后的待对齐标记与遮蔽行：重新对齐完成，或者按首次基线重生。
  Future<void> _clearRestoreMarker() async {
    await _cursors.delete(RevisionCursor.syncRestoreAlign);
    await _shadows.clear();
  }

  /// 第一次同步：先把服务端已有的提交全部拉下来，再把本机独有、云端还没有的
  /// 行作为基线提交上传，最后补齐这些行引用到的附件（同步方案 3.6）。
  ///
  /// 服务端的每一行都来自某条远端提交，所以拉取时记下被远端提交触及过的
  /// “表名 + 主键”，组装基线时跳过这些行：它们已经由服务端序列表达，本机这份
  /// 只是拉下来的副本，再传一遍只会让序列多出一整份数据。全新设备本机投影为空
  /// 时一条基线也不产生，服务端序列长度不变，与 `git clone` 一致。被跳过行的
  /// 附件哈希不单独上传：它的内容随那条远端提交可以在服务端取到；被保留下来的
  /// 行如果也引用同一个哈希，按引用去重之后照常上传。
  ///
  /// 收尾时把两个同步位置写进库里的 `revision_cursor`：拉取之后的本机 `HEAD`
  /// 都已经在服务端序列里（推送位置从这里开始），服务端位置记下基线推完之后的
  /// 序列长度。
  Future<
    ({int serverHead, int pulled, int pushed, int uploaded, int downloaded})
  >
  _bootstrap(String deviceId) async {
    var pulled = 0;
    var downloaded = 0;
    var serverHead = 0;
    // 这次拉取触及过的行，按“表名 + 主键”记；只在首次同步里用，收尾即丢弃。
    final touchedRows = <(String, String)>{};
    final remoteHead = await account.call(
      (client, token) => client.head(token),
    );
    if (remoteHead.head > 0) {
      final result = await _pull(
        serverHead: 0,
        deviceId: deviceId,
        persist: false,
        downloaded: (count) => downloaded += count,
        touchedRows: touchedRows,
      );
      pulled = result.pulled;
      serverHead = result.serverHead;
    }
    final headAfterPull = await engine.headId(database.raw);
    final projection = await engine.readProjection(database.raw);
    final changes = <RevisionChange>[];
    var seq = 1;
    for (final table in versionedTableNames) {
      final rows = projection[table] ?? const <String, TypedRow>{};
      for (final entry in rows.entries) {
        // 被远端提交触及过的行已经由服务端序列表达，不进基线。
        if (touchedRows.contains((table, entry.key))) continue;
        changes.add(
          RevisionChange(
            commitId: 0,
            seq: seq++,
            table: table,
            rowKey: entry.key,
            op: ChangeOp.insert,
            after: entry.value,
          ),
        );
      }
    }
    var pushed = 0;
    var baseSeq = serverHead;
    // 基线推送完成、两个同步位置收尾之后，本机没有待推送提交；这时最后一条
    // 基线提交带上当前整库摘要，其他设备拉到它之后可以比较（同步方案 3.5）。
    // 读 HEAD、整库重算之间又有本机写入，或者这次拉取有被跳过的变化（本机状态
    // 与云端对不上），就不带，避免声明一个不成立的云端状态。
    String? baselineDigest;
    if (changes.isNotEmpty && _pulledSkipped == 0 && !_knownDigestMismatch) {
      final headBefore = await engine.headId(database.raw);
      final digest = await revisions.currentStateDigest();
      if (await engine.headId(database.raw) == headBefore) {
        baselineDigest = digest;
      }
    }
    await _pushBatches(
      Stream.fromIterable(
        _baselineCommits(deviceId, changes, stateDigest: baselineDigest),
      ),
      baseSeq,
      (head, count) async {
        baseSeq = head;
        pushed += count;
      },
    );
    // 附件只跟着基线里的行走：被跳过行的哈希按“服务端已有”处理，本机保留行
    // 也引用到同一个哈希时仍然上传，集合去重。
    final uploaded = await _uploadAssets(AssetStore.hashesInChanges(changes));
    _ensureIdentity();
    await _saveServerHead(baseSeq);
    await _savePushed(headAfterPull);
    // 首次基线把本机独有的内容上传，编号不大于它的本机提交不再单独推送，
    // 换账号或服务端清空后重建时留下的遮蔽行一并清掉。
    await _shadows.deleteSettled(headAfterPull);
    return (
      serverHead: baseSeq,
      pulled: pulled,
      pushed: pushed,
      uploaded: uploaded,
      downloaded: downloaded,
    );
  }

  /// 把本机独有的行按每片最多 [_baselineChunk] 处变化组装成基线提交。
  ///
  /// [stateDigest] 非空时附在最后一片上：整条基线推完之后本机没有待推送提交，
  /// 这个摘要就是推完之后云端应有的状态（同步方案 3.5）。
  Iterable<ServerCommit> _baselineCommits(
    String deviceId,
    List<RevisionChange> changes, {
    String? stateDigest,
  }) sync* {
    var index = 0;
    while (index < changes.length) {
      final start = index;
      final payload = <ServerChange>[];
      var bytes = 512; // 提交元数据和数组分隔符。
      while (index < changes.length && payload.length < _baselineChunk) {
        final change = _toServerChange(changes[index]);
        final size = _syncBytes(change.toJson()) + 1;
        if (bytes + size > _commitBytes) {
          if (payload.isEmpty) throw _oversizedCommit;
          break;
        }
        bytes += size;
        payload.add(change);
        index++;
      }
      yield ServerCommit(
        requestId: _baselineUid(deviceId, changes.sublist(start, index)),
        deviceId: deviceId,
        schemaVersion: zhixinSchemaVersion,
        actor: 'system',
        action: '首次同步基线',
        createdAt: formatDateTime(clock()),
        changes: payload,
        // 这是最后一片时整条基线已经组装完，摘要挂在它上面。
        stateDigest: index >= changes.length ? stateDigest : null,
      );
    }
  }

  Future<void> _pushBatches(
    Stream<ServerCommit> commits,
    int baseSeq,
    Future<void> Function(int head, int count) saved,
  ) async {
    final batch = <ServerCommit>[];
    var bytes = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      for (var attempt = 0; ; attempt++) {
        _ensureIdentity();
        try {
          baseSeq = await account.call(
            (client, token) =>
                client.push(token, baseSeq: baseSeq, commits: batch),
          );
          break;
        } on ServerProblem catch (error) {
          if (error.status == 400 && batch.isNotEmpty) {
            // 服务端只说“提交校验失败”，本机据此定位是哪一批、哪一条。
            recordFailure(
              StateError(
                '同步被拒：批次 ${batch.length} 条，'
                '首条 ${batch.first.requestId}，末条 ${batch.last.requestId}，'
                'extra=${error.extra}',
              ),
              StackTrace.current,
              kind: 'cloud_sync_batch',
            );
          }
          final retry = error.retryAfterSeconds;
          if (error.code != 'rate_limited' ||
              attempt >= 2 ||
              retry == null ||
              retry < 1 ||
              retry > 5) {
            rethrow;
          }
          await Future<void>.delayed(Duration(seconds: retry));
        }
      }
      await saved(baseSeq, batch.length);
      batch.clear();
      bytes = 0;
    }

    await for (final commit in commits) {
      _ensureIdentity();
      final size = _syncBytes(commit.toJson());
      if (size > _commitBytes) throw _oversizedCommit;
      if (batch.length == _pushBatch || bytes + size + 1 > _pushBytes) {
        await flush();
      }
      batch.add(commit);
      bytes += size + 1;
    }
    await flush();
  }

  static final _goJsonEscapes = RegExp('[<>&\u2028\u2029]');

  static int _syncBytes(Object value) {
    final json = jsonEncode(value);
    // Go 的 JSON 序列化会将这些字符写成六字节转义序列。
    return utf8.encode(json).length +
        _goJsonEscapes.allMatches(json).fold(0, (extra, match) {
          return extra + (json.codeUnitAt(match.start) > 127 ? 3 : 5);
        });
  }

  static const _oversizedCommit = ServerProblem(
    code: 'payload_too_large',
    status: 413,
    extra: {'resource': 'sync'},
    detail: '单条同步提交超过服务端允许的大小',
  );

  /// 拉取服务端位置 [serverHead] 之后的提交并应用到本机，返回推进后的服务端
  /// 位置；[persist] 为真时每页推进之后都写进库里的读取位置。
  ///
  /// [touchedRows] 非空时记下每条远端提交触及过的“表名 + 主键”（变化明细里
  /// 出现的每一行，含被跳过与被删除的）：首次同步据此判断本机投影里哪些行已经
  /// 由服务端序列表达，只把剩下的行作为基线上传（同步方案 3.6）。
  ///
  /// 拉完之后如果最新一条提交带着整库摘要，比较一次本机摘要：顺序是“拉取 →
  /// 比较 → 推送”，只有本机没有待推送提交时本机 `HEAD` 才对应这条提交，整库
  /// 重算的摘要才能直接与它比较（见 `_comparePulledDigest`）。
  Future<({int serverHead, int pulled, int downloaded})> _pull({
    required int serverHead,
    required String deviceId,
    required void Function(int count) downloaded,
    bool persist = true,
    Set<(String, String)>? touchedRows,
  }) async {
    var current = serverHead;
    var pulled = 0;
    var downloadCount = 0;
    // 这一次拉取最后读到的一条提交带的摘要；最新一条没有带时为空。
    String? latestDigest;
    while (true) {
      _ensureIdentity();
      final page = await account.call(
        (client, token) => client.pull(token, after: current),
      );
      if (page.commits.isEmpty) {
        current = page.head;
        if (persist) await _saveServerHead(current);
        break;
      }
      final hashes = <String>{};
      for (final commit in page.commits) {
        _ensureIdentity();
        // 被这条远端提交取代的本机格子由 `applyChanges` 在同一个事务里登记进
        // `sync_shadow`，这一层不用再记（ADR-0040）。
        final applied = await _applyRemote(commit);
        _pulledSkipped += applied.skipped;
        if (touchedRows != null) {
          // 服务端序列里的行全部来自远端提交：变化明细里出现过的行即被触及，
          // 本机这份只是副本。被跳过或被删除的变化也记下，对应的本机行要么已经
          // 是远端值，要么本来就不存在，都不该进基线。
          for (final change in commit.changes) {
            touchedRows.add((change.table, change.rowKey));
          }
        }
        hashes.addAll(applied.assetHashes);
        pulled++;
      }
      latestDigest = page.commits.last.stateDigest;
      current = page.commits.last.seq ?? page.head;
      _ensureIdentity();
      if (persist) await _saveServerHead(current);
      final fetched = await _downloadAssets(hashes);
      downloadCount += fetched;
      downloaded(fetched);
      if (!page.hasMore) break;
    }
    if (latestDigest != null) {
      await _comparePulledDigest(latestDigest, serverHead: current);
    }
    return (serverHead: current, pulled: pulled, downloaded: downloadCount);
  }

  /// 拉取到带摘要的最新一条提交之后比较摘要（同步方案 3.5）。
  ///
  /// 只有本机也没有待推送提交时才比：这时本机 `HEAD` 对应刚应用的那条远端
  /// 提交，按当前业务表整库重算的摘要与它可以直接比较。比较期间又写了一条本机
  /// 提交，`HEAD` 就往前走了，这一次跳过，等下一轮同步再比。结果写进同步状态
  /// （账号页据此显示“本机与云端不一致”），不一致时另记一条诊断。
  Future<void> _comparePulledDigest(
    String cloudDigest, {
    required int serverHead,
  }) async {
    final pushed = await _pushedPosition();
    if ((await revisions.commitsAfter(pushed)).isNotEmpty) return;
    final localDigest = await revisions.currentStateDigest();
    if ((await revisions.commitsAfter(pushed)).isNotEmpty) return;
    _ensureIdentity();
    final matched = localDigest == cloudDigest;
    await _saveDigestMismatch(!matched);
    if (!matched) {
      recordFailure(
        StateError(
          '同步摘要不一致：本机 $localDigest，云端 $cloudDigest，'
          '服务端位置 $serverHead',
        ),
        StackTrace.current,
        kind: 'cloud_sync_digest',
      );
    }
  }

  /// 把“本机与云端不一致”写进这个身份的同步状态；相同值不重复写文件。
  ///
  /// 首次同步时偏好文件里可能还没有同步状态，这里按当前账号与实例建一份，
  /// 收尾保存“上次同步时间”时会从文件重读，不会把它盖掉。
  Future<void> _saveDigestMismatch(bool mismatch) async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) return;
    final origin = await account.serverOrigin();
    final userId = snapshot.session!.userId;
    final stored = await preferences.syncState();
    final base = stored != null && _sameIdentity(stored, userId, origin)
        ? stored
        : SyncState(userId: userId, serverOrigin: origin);
    if (base.digestMismatch == mismatch) return;
    await preferences.saveSyncState(base.copyWith(digestMismatch: mismatch));
  }

  /// 修复完成之后推进“上次同步时间”，与普通同步收尾一致。
  Future<void> _markSynced() async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) return;
    final origin = await account.serverOrigin();
    final stored = await preferences.syncState();
    if (stored == null ||
        !_sameIdentity(stored, snapshot.session!.userId, origin)) {
      return;
    }
    await preferences.saveSyncState(stored.copyWith(syncedAt: clock()));
  }

  /// 推送本机推送位置之后的提交；服务端位置变化时先拉取再重试。
  ///
  /// 待推送列表已经去掉远端提交（`kind = remote`）：它们对应服务端已有的提交，
  /// 再推回去只会在序列里多一份。每条本机提交按格变基：被 `sync_shadow` 遮蔽的
  /// 格子（编号不大于遮蔽行 `upto_commit` 的改动）不再推送，剩下多少推多少；剩余
  /// 为空的提交不推，推送位置照常前进。推送成功之后把推送位置推进到最后一条
  /// 考虑过的提交，没推任何提交时推进到当前 `HEAD`，并删掉已经越过推送位置的
  /// 遮蔽行（ADR-0040）。
  ///
  /// [pullBefore] 为假时服务端位置往前走了也不拉取，只按新位置重新推送：整库
  /// 恢复之后的重新对齐不能拉取，否则会把恢复前的改动带回来（同步方案 3.4）。
  Future<({int serverHead, int pushed})> _push({
    required int serverHead,
    required int pushedThrough,
    required String deviceId,
    required void Function(int count) uploaded,
    required void Function(({int pulled, int downloaded}) result) onPulled,
    bool pullBefore = true,
  }) async {
    var currentHead = serverHead;
    var currentPushed = pushedThrough;
    for (var attempt = 0; attempt < 3; attempt++) {
      _ensureIdentity();
      final headNow = await account.call((client, token) => client.head(token));
      if (headNow.head != currentHead) {
        if (pullBefore) {
          final pulled = await _pull(
            serverHead: currentHead,
            deviceId: deviceId,
            downloaded: (count) {},
          );
          currentHead = pulled.serverHead;
          onPulled((pulled: pulled.pulled, downloaded: pulled.downloaded));
        } else {
          currentHead = headNow.head;
          _ensureIdentity();
          await _saveServerHead(currentHead);
        }
      }
      final localHead = await engine.headId(database.raw);
      final pending = await revisions.commitsAfter(currentPushed);
      if (pending.isEmpty) {
        _ensureIdentity();
        await _savePushed(localHead);
        await _shadows.deleteSettled(localHead);
        currentPushed = localHead;
        return (serverHead: currentHead, pushed: 0);
      }
      // 遮蔽行一次读出，再按提交编号逐条判断：每条提交的变化只读一次，既算出
      // 剩余部分，也用来组装推送内容与附件哈希。
      final shadows = await _shadows.list();
      final remainingByCommit = <int, List<RevisionChange>>{};
      final toPush = <RevisionCommit>[];
      for (final commit in pending) {
        final changes = await engine.changesFor(database.raw, commit.id);
        final remaining = _rebaseChanges(changes, commit.id, shadows);
        if (remaining.isEmpty) continue;
        remainingByCommit[commit.id] = remaining;
        toPush.add(commit);
      }
      if (toPush.isEmpty) {
        _ensureIdentity();
        await _savePushed(pending.last.id);
        await _shadows.deleteSettled(pending.last.id);
        currentPushed = pending.last.id;
        return (serverHead: currentHead, pushed: 0);
      }
      // 推送完成且本机没有待推送提交时，把当前摘要附在最后一条推上去的提交上
      // （同步方案 3.5）。`pending.last` 之后没有新的本机提交才说明推完之后没
      // 有待推送提交（拉取形成的远端提交不算）；读提交与整库重算之间又写了本机
      // 提交就不带，避免声明一个不含那次写入的云端状态。这次同步有被跳过的远端
      // 变化时本机与云端对不上，也不带。
      String? tailDigest;
      if (!_knownDigestMismatch &&
          _pulledSkipped == 0 &&
          (await revisions.commitsAfter(pending.last.id)).isEmpty) {
        final digest = await revisions.currentStateDigest();
        if ((await revisions.commitsAfter(pending.last.id)).isEmpty) {
          tailDigest = digest;
        }
      }
      final assetHashes = <String>{};
      var pushed = 0;
      try {
        Stream<ServerCommit> payloads() async* {
          for (var index = 0; index < toPush.length; index++) {
            final commit = toPush[index];
            final changes = remainingByCommit[commit.id]!;
            assetHashes.addAll(AssetStore.hashesInChanges(changes));
            yield ServerCommit(
              requestId: commit.uid,
              deviceId: deviceId,
              schemaVersion: zhixinSchemaVersion,
              actor: _actorOf(commit.actor),
              action: commit.action,
              createdAt: formatDateTime(commit.createdAt ?? clock()),
              changes: [for (final change in changes) _toServerChange(change)],
              stateDigest: index == toPush.length - 1 ? tailDigest : null,
            );
          }
        }

        await _pushBatches(payloads(), currentHead, (head, count) async {
          pushed += count;
          currentHead = head;
          _ensureIdentity();
          await _saveServerHead(currentHead);
        });
      } on ServerProblem catch (error) {
        if (!error.isConflict) rethrow;
        final head = error.extra['head'];
        currentHead = head is num ? head.toInt() : currentHead;
        _ensureIdentity();
        await _saveServerHead(currentHead);
        continue;
      }
      uploaded(await _uploadAssets(assetHashes));
      _ensureIdentity();
      // 推送位置只覆盖这次真正考虑过的提交；同步途中新产生的提交留下一轮。
      await _savePushed(pending.last.id);
      await _shadows.deleteSettled(pending.last.id);
      currentPushed = pending.last.id;
      return (serverHead: currentHead, pushed: pushed);
    }
    throw const ServerProblem(
      code: 'conflict',
      status: 409,
      detail: '服务端位置连续变化，这次同步没有完成',
    );
  }

  Future<({RevisionCommit? commit, Set<String> assetHashes, int skipped})>
  _applyRemote(ServerCommit commit) async {
    final changes = <RevisionChange>[];
    var seq = 1;
    for (final change in commit.changes) {
      final before = change.before == null
          ? null
          : decodeTypedRow(jsonEncode(change.before));
      final after = change.after == null
          ? null
          : decodeTypedRow(jsonEncode(change.after));
      changes.add(
        RevisionChange(
          commitId: 0,
          seq: seq++,
          table: change.table,
          rowKey: change.rowKey,
          op: ChangeOp.fromValue(change.op),
          before: before,
          after: after,
        ),
      );
    }
    final actor = const {'user', 'ai', 'system'}.contains(commit.actor)
        ? commit.actor
        : 'user';
    final result = await revisions.applyRemoteCommit(
      uid: commit.requestId,
      action: commit.action.isEmpty ? '从其他设备同步' : commit.action,
      actor: actor,
      changes: changes,
      // 服务端带来的设备标识与作者创建时间原样落到本机提交行；本机提交的两列
      // 仍为空与等值不变（方案 3.12）。
      originDevice: commit.deviceId,
      authoredAt: optionalDateTime(commit.createdAt),
    );
    if (result.skipped > 0) {
      recordFailure(
        StateError('同步 ${commit.requestId} 时跳过 ${result.skipped} 条对不上的变化'),
        StackTrace.current,
        kind: 'cloud_sync_apply_skipped',
      );
    }
    return (
      commit: result.commit,
      assetHashes: AssetStore.hashesInChanges(changes),
      skipped: result.skipped,
    );
  }

  /// 一条待推送提交去掉被遮蔽的格子之后的剩余部分。
  ///
  /// 遮蔽行只在编号不大于它的提交上生效：这些格子已经被远端值取代，再推回去
  /// 等于把旧值顶回服务端；编号更大的提交是拉取之后才写下的，照常推送。列级
  /// 遮蔽只去掉对应的列，整行遮蔽把这一行的变化整条去掉，剩下的列尽量推。
  /// 剩余部分的 `before` 沿用原值：被保留下来的列远端没有动过，其他设备上这些
  /// 列的旧值与本机一致，不需要改写（ADR-0040）。
  List<RevisionChange> _rebaseChanges(
    List<RevisionChange> changes,
    int commitId,
    List<RevisionShadow> shadows,
  ) {
    if (shadows.isEmpty) return changes;
    final wholeRows = <(String, String)>{};
    final columns = <(String, String), Set<String>>{};
    for (final shadow in shadows) {
      if (shadow.uptoCommit < commitId) continue;
      final key = (shadow.table, shadow.rowKey);
      if (shadow.isWholeRow) {
        wholeRows.add(key);
      } else {
        columns.putIfAbsent(key, () => <String>{}).add(shadow.column);
      }
    }
    if (wholeRows.isEmpty && columns.isEmpty) return changes;
    final remaining = <RevisionChange>[];
    for (final change in changes) {
      final key = (change.table, change.rowKey);
      if (wholeRows.contains(key)) continue;
      final shadowed = columns[key];
      if (shadowed == null || change.op != ChangeOp.update) {
        remaining.add(change);
        continue;
      }
      final after = {
        for (final entry
            in (change.after ?? const <String, RevisionValue>{}).entries)
          if (!shadowed.contains(entry.key)) entry.key: entry.value,
      };
      // 这一行的列级变化全部被遮蔽时整条不推；还剩列时只推剩下的列。
      if (after.isEmpty) continue;
      final before = {
        for (final entry
            in (change.before ?? const <String, RevisionValue>{}).entries)
          if (!shadowed.contains(entry.key)) entry.key: entry.value,
      };
      remaining.add(
        RevisionChange(
          commitId: change.commitId,
          seq: change.seq,
          table: change.table,
          rowKey: change.rowKey,
          op: change.op,
          before: before.isEmpty ? null : before,
          after: after,
        ),
      );
    }
    return remaining;
  }

  Future<int> _uploadAssets(Set<String> hashes) async {
    if (hashes.isEmpty) return 0;
    final local = await assets.objectHashes(database.raw);
    var uploaded = 0;
    for (final hash in hashes) {
      _ensureIdentity();
      if (!local.contains(hash)) continue;
      final exists = await account.call(
        (client, token) => client.blobExists(token, hash),
      );
      if (exists != null) continue;
      final bytes = await assets.readBytes(database.raw, hash);
      if (bytes == null) continue;
      // 账号附件总量已满时服务端返回 storage_full；异常向上抛出，这一轮上传
      // 到此停止，界面按已用与上限说明，不静默跳过也不反复重试。
      await account.call(
        (client, token) => client.blobUpload(token, hash, bytes),
      );
      uploaded++;
    }
    return uploaded;
  }

  Future<int> _downloadAssets(Set<String> hashes) async {
    if (hashes.isEmpty) return 0;
    final local = await assets.objectHashes(database.raw);
    final fetched = <String, List<int>>{};
    for (final hash in hashes) {
      _ensureIdentity();
      if (local.contains(hash)) continue;
      final bytes = await account.call(
        (client, token) => client.blobDownload(token, hash),
      );
      if (AssetStore.hashBytes(bytes) != hash) {
        recordFailure(
          StateError('服务端返回的附件 $hash 校验失败'),
          StackTrace.current,
          kind: 'cloud_sync_asset_hash',
        );
        continue;
      }
      fetched[hash] = bytes;
    }
    if (fetched.isEmpty) return 0;
    await transactions.run((txn) async {
      for (final entry in fetched.entries) {
        await assets.putBytes(
          txn.executor,
          entry.key,
          Uint8List.fromList(entry.value),
        );
      }
    }, label: '同步附件');
    for (final entry in fetched.entries) {
      try {
        await cache.write(entry.key, Uint8List.fromList(entry.value));
      } catch (error, stack) {
        recordFailure(error, stack, kind: 'cloud_sync_assetcache');
      }
    }
    return fetched.length;
  }

  ServerChange _toServerChange(RevisionChange change) => ServerChange(
    table: change.table,
    rowKey: change.rowKey,
    op: change.op.value,
    before: change.before == null ? null : typedRowToJson(change.before!),
    after: change.after == null ? null : typedRowToJson(change.after!),
  );

  /// 基线提交的 uid：按这一块变更明细的内容与设备算出，同一块数据重试时标识
  /// 不变，服务端的永久去重才能把失败之后的重发当成重试。基线是本机投影的
  /// 一次性上传，没有对应的 `revision_commit` 行，因此不占用本地提交的 uid。
  String _baselineUid(String deviceId, List<RevisionChange> chunk) {
    final prefix = deviceId.length >= 8 ? deviceId.substring(0, 8) : deviceId;
    final digest = sha256
        .convert(
          utf8.encode(jsonEncode([for (final change in chunk) change.toRow()])),
        )
        .toString()
        .substring(0, 32);
    return '$prefix-$digest';
  }

  String _actorOf(String actor) =>
      const {'user', 'ai', 'system'}.contains(actor) ? actor : 'user';

  String _describe(Object error) => switch (error) {
    ServerProblem(:final userMessage) => userMessage,
    AccountSignedOut(:final userMessage) => userMessage,
    SyncSchemaMismatch() => error.toString(),
    SyncIdentityChanged() => error.toString(),
    BaselineConfirmationRequired(:final message) => message,
    _ => '同步没有完成',
  };
}
