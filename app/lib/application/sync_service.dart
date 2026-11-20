import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/cloud/cloud_preferences_store.dart';
import '../data/cloud/server_client.dart';
import '../data/db/app_database.dart' show zhixinSchemaVersion;
import '../data/db/guarded_database.dart';
import '../data/db/write_transactions.dart';
import '../data/revisions/asset_store.dart';
import '../data/revisions/revision_cursor.dart';
import '../data/revisions/revision_engine.dart';
import '../data/revisions/revision_models.dart';
import '../data/revisions/revision_service.dart';
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

/// 这个账号第一次同步：需要先把本机现有记录作为基线上传，必须由用户确认。
class BaselineConfirmationRequired implements Exception {
  const BaselineConfirmationRequired(this.localCommits);

  /// 本机当前 HEAD 对应的提交数，用来告诉用户会上传多少。
  final int localCommits;

  String get message =>
      '这个账号还没有同步过。首次同步会把本机现有的 $localCommits 条提交作为基线'
      '完整上传到这个账号的云端，其他登录这个账号的设备也会看到这些记录。';

  @override
  String toString() => message;
}

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

/// 按提交序列与服务端同步：首次上传当前数据为基线，之后拉取远端提交、在本机
/// 应用为新的提交，再推送本机新提交，并把提交里引用的附件按哈希补齐。
///
/// 服务端只保存线性序列，不解析内容；冲突按“后到达的覆盖先到达的”处理，被覆盖
/// 的值留在提交历史里（[server/README](../../../server/README.md) 的同步协议）。
/// 同步只读写本机数据库与网络，不换库、不清空，界面通过数据层已有的表通知重读。
/// 推送给服务端的请求标识。
///
/// 服务端要求它非空且不超过 64 个字节；本地有些命令用 JSON 编码的请求标识做重复
/// 提交判断（例如加记忆、更正材料页），既可能变长，也可能带中文，按 UTF-8 字节
/// 算会超过上限，整批推送因此被拒绝。超长或为空时改用按提交编号生成的稳定标识，
/// 同一提交重试时标识不变，服务端的去重照常生效。
String syncRequestIdFor({
  required String? stored,
  required String deviceId,
  required int commitId,
}) {
  final existing = stored?.trim() ?? '';
  if (existing.isNotEmpty && utf8.encode(existing).length <= 64) {
    return existing;
  }
  final prefix = deviceId.length >= 8 ? deviceId.substring(0, 8) : deviceId;
  return 'l-$prefix-$commitId';
}

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

  /// 这次同步里被远端提交真正改过的格子（表、主键、列；整行变化记空列）。
  ///
  /// 推送时跳过改动落在这些格子上的本机提交：它们的值已经被拉下来的远端值
  /// 覆盖，再推回服务端等于把旧值顶回去，另一台设备与本机就此分叉。这与 git
  /// 先拉取再推送、推送的不是被合并掉的旧提交是同一个道理（ADR-0039）。
  final Set<({String table, String rowKey, String? column})> _pulledOverwrites =
      {};
  bool _disposed = false;

  /// 这次同步开始时的身份代次；切换账号或实例之后进行中的同步据此丢弃结果。
  int? _runEpoch;

  bool get syncing => _running != null;

  /// 同步位置：推送读到哪里与服务端拉到哪个位置，都存在库里的
  /// `revision_cursor` 表，随整库恢复一起回去（ADR-0039）。
  RevisionCursors get _cursors => RevisionCursors(database.raw, clock: clock);

  Future<int> _pushedPosition() => _cursors.position(RevisionCursor.syncPushed);

  Future<int> _serverHeadPosition() =>
      _cursors.position(RevisionCursor.syncServerHead);

  /// 记下服务端拉到哪个位置；这个读者不阻塞裁剪。
  Future<void> _saveServerHead(int position) =>
      _cursors.set(RevisionCursor.syncServerHead, position, blocking: false);

  /// 记下本机已经推送到哪里；推送会丢数据，落后的位置阻止裁剪与清理历史。
  Future<void> _savePushed(int position) =>
      _cursors.set(RevisionCursor.syncPushed, position, blocking: true);

  /// 账号与实例是否还是这份同步状态对应的那一个；换过之后旧状态不能用。
  bool _sameIdentity(SyncState? state, String userId, String origin) =>
      state != null && state.userId == userId && state.serverOrigin == origin;

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
    final origin = await account.serverOrigin();
    final ownState = _sameIdentity(state, snapshot.session!.userId, origin)
        ? state
        : null;
    if (ownState == null) {
      // 还没有为这个账号建立同步状态：本机现有记录会整份作为首次基线上传。
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
        lastError: _lastError,
      );
    }
    final pushed = await _pushedPosition();
    return SyncStatus(
      signedIn: true,
      accountLabel: snapshot.displayLabel,
      autoSync: snapshot.autoSync,
      syncing: syncing,
      pendingCommits: (await revisions.commitsAfter(pushed)).length,
      localHead: localHead,
      serverHead: await _serverHeadPosition(),
      needsBootstrap: false,
      lastSyncedAt: ownState.syncedAt,
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
  /// 的“立即同步”会先问一次。
  Future<void> schedule({Duration delay = const Duration(seconds: 5)}) async {
    if (_disposed) return;
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn || !snapshot.autoSync) return;
    final state = await preferences.syncState();
    final origin = await account.serverOrigin();
    final localHead = await engine.headId(database.raw);
    final ownState = _sameIdentity(state, snapshot.session!.userId, origin)
        ? state
        : null;
    if (ownState == null && localHead > 0) return;
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
  /// 库里的同步位置不在这里删：下次同步按首次基线重新对齐时会连同两个位置
  /// 一起重写，旧位置不会把新账号的提交当成已经推送过。
  Future<void> clearState() => preferences.clearSyncState();

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<SyncResult> _sync({bool confirmBaseline = false}) async {
    _lastError = null;
    _pulledOverwrites.clear();
    var pulled = 0;
    var pushed = 0;
    var uploaded = 0;
    var downloaded = 0;
    final deviceId = await account.deviceId();
    final epoch = account.identityEpoch;
    final origin = await account.serverOrigin();
    _runEpoch = epoch;
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
      final localHead = await engine.headId(database.raw);
      var state = await preferences.syncState();
      if (state != null && !_sameIdentity(state, userId, origin)) {
        // 换了账号或实例：旧状态与库里的同步位置都不再对应这个身份。
        await preferences.clearSyncState();
        state = null;
      }
      var serverHead = state == null ? 0 : await _serverHeadPosition();
      var pushedThrough = state == null ? 0 : await _pushedPosition();
      if (state != null && remoteHead.head < serverHead) {
        // 服务端序列被清空过，服务端位置回到 0，需要重新上传基线；位置在
        // 首次同步收尾时随基线一起重写。
        await preferences.clearSyncState();
        state = null;
        serverHead = 0;
        pushedThrough = 0;
      }

      if (state == null) {
        // 首次同步（或服务端被清空后重建）会把本机记录整份上传，必须先确认；
        // 本机没有记录时不需要确认。
        if (localHead > 0 && !confirmBaseline) {
          throw BaselineConfirmationRequired(localHead);
        }
        final boot = await _bootstrap(deviceId, origin, userId);
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
      }
      _ensureIdentity();
      final finalState = state.copyWith(syncedAt: clock());
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
    }
  }

  /// 第一次同步：先把服务端已有的提交拉下来，再把本机当前数据作为一份基线
  /// 上传，最后补齐附件。本机历史仍然完整，后续写入按提交增量推送。
  ///
  /// 收尾时把两个同步位置写进库里的 `revision_cursor`：拉取之后的本机 `HEAD`
  /// 都已经在服务端序列里（推送位置从这里开始），服务端位置记下基线推完之后的
  /// 序列长度。
  Future<
    ({int serverHead, int pulled, int pushed, int uploaded, int downloaded})
  >
  _bootstrap(String deviceId, String origin, String userId) async {
    var pulled = 0;
    var downloaded = 0;
    var serverHead = 0;
    final remoteHead = await account.call(
      (client, token) => client.head(token),
    );
    if (remoteHead.head > 0) {
      final result = await _pull(
        serverHead: 0,
        deviceId: deviceId,
        persist: false,
        downloaded: (count) => downloaded += count,
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
    await _pushBatches(
      Stream.fromIterable(_baselineCommits(deviceId, changes)),
      baseSeq,
      (head, count) async {
        baseSeq = head;
        pushed += count;
      },
    );
    final uploaded = await _uploadAssets(
      AssetStore.hashesInProjection(projection),
    );
    _ensureIdentity();
    await _saveServerHead(baseSeq);
    await _savePushed(headAfterPull);
    await preferences.saveSyncState(
      SyncState(userId: userId, serverOrigin: origin, syncedAt: clock()),
    );
    return (
      serverHead: baseSeq,
      pulled: pulled,
      pushed: pushed,
      uploaded: uploaded,
      downloaded: downloaded,
    );
  }

  Iterable<ServerCommit> _baselineCommits(
    String deviceId,
    List<RevisionChange> changes,
  ) sync* {
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
        requestId: _baselineRequestId(
          deviceId,
          start,
          changes.sublist(start, index),
        ),
        deviceId: deviceId,
        schemaVersion: zhixinSchemaVersion,
        actor: 'system',
        action: '首次同步基线',
        createdAt: formatDateTime(clock()),
        changes: payload,
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
  Future<({int serverHead, int pulled, int downloaded})> _pull({
    required int serverHead,
    required String deviceId,
    required void Function(int count) downloaded,
    bool persist = true,
  }) async {
    var current = serverHead;
    var pulled = 0;
    var downloadCount = 0;
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
        final applied = await _applyRemote(commit);
        hashes.addAll(applied.assetHashes);
        _recordPulledChanges(applied.appliedChanges);
        pulled++;
      }
      current = page.commits.last.seq ?? page.head;
      _ensureIdentity();
      if (persist) await _saveServerHead(current);
      final fetched = await _downloadAssets(hashes);
      downloadCount += fetched;
      downloaded(fetched);
      if (!page.hasMore) break;
    }
    return (serverHead: current, pulled: pulled, downloaded: downloadCount);
  }

  /// 推送本机推送位置之后的提交；服务端位置变化时先拉取再重试。
  ///
  /// 待推送列表已经去掉远端提交（`kind = remote`）：它们对应服务端已有的提交，
  /// 再推回去只会在序列里多一份。改动已经被这次拉取覆盖的本机提交同样不推：
  /// 远端值已经写进本机，再把这些提交推上去等于把旧值顶回服务端。推送成功之后
  /// 把推送位置推进到最后一条考虑过的提交，没推任何提交时推进到当前 `HEAD`。
  Future<({int serverHead, int pushed})> _push({
    required int serverHead,
    required int pushedThrough,
    required String deviceId,
    required void Function(int count) uploaded,
    required void Function(({int pulled, int downloaded}) result) onPulled,
  }) async {
    var currentHead = serverHead;
    var currentPushed = pushedThrough;
    for (var attempt = 0; attempt < 3; attempt++) {
      _ensureIdentity();
      final headNow = await account.call((client, token) => client.head(token));
      if (headNow.head != currentHead) {
        final pulled = await _pull(
          serverHead: currentHead,
          deviceId: deviceId,
          downloaded: (count) {},
        );
        currentHead = pulled.serverHead;
        onPulled((pulled: pulled.pulled, downloaded: pulled.downloaded));
      }
      final localHead = await engine.headId(database.raw);
      final pending = await revisions.commitsAfter(currentPushed);
      if (pending.isEmpty) {
        _ensureIdentity();
        await _savePushed(localHead);
        currentPushed = localHead;
        return (serverHead: currentHead, pushed: 0);
      }
      // 每条提交的变化只读一次：既判断它是否已经被这次拉取覆盖，也用来组装
      // 推送内容。被覆盖的提交不再推送，位置照常前进，等同于把它们记为已被
      // 远端值取代（ADR-0039）。
      final changesByCommit = <int, List<RevisionChange>>{};
      final toPush = <RevisionCommit>[];
      for (final commit in pending) {
        final changes = await engine.changesFor(database.raw, commit.id);
        changesByCommit[commit.id] = changes;
        if (_coveredByPull(changes)) continue;
        toPush.add(commit);
      }
      if (toPush.isEmpty) {
        _ensureIdentity();
        await _savePushed(pending.last.id);
        currentPushed = pending.last.id;
        return (serverHead: currentHead, pushed: 0);
      }
      final assetHashes = <String>{};
      var pushed = 0;
      try {
        Stream<ServerCommit> payloads() async* {
          for (final commit in toPush) {
            final changes = changesByCommit[commit.id]!;
            assetHashes.addAll(AssetStore.hashesInChanges(changes));
            yield ServerCommit(
              requestId: _requestIdFor(commit, deviceId),
              deviceId: deviceId,
              schemaVersion: zhixinSchemaVersion,
              actor: _actorOf(commit.actor),
              action: commit.action,
              createdAt: formatDateTime(commit.createdAt ?? clock()),
              changes: [for (final change in changes) _toServerChange(change)],
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
      // 推送位置只覆盖这次真正推上去的提交；同步途中新产生的提交留下一轮。
      await _savePushed(pending.last.id);
      currentPushed = pending.last.id;
      return (serverHead: currentHead, pushed: pushed);
    }
    throw const ServerProblem(
      code: 'conflict',
      status: 409,
      detail: '服务端位置连续变化，这次同步没有完成',
    );
  }

  Future<
    ({
      RevisionCommit? commit,
      Set<String> assetHashes,
      int skipped,
      List<RevisionChange> appliedChanges,
    })
  >
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
      requestId: commit.requestId,
      action: commit.action.isEmpty ? '从其他设备同步' : commit.action,
      actor: actor,
      changes: changes,
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
      appliedChanges: result.appliedChanges,
    );
  }

  /// 记下拉取时真正写进本机的格子；整行变化（新增、删除）记成空列。
  void _recordPulledChanges(Iterable<RevisionChange> changes) {
    for (final change in changes) {
      if (change.op == ChangeOp.update) {
        for (final column in {
          ...?change.after?.keys,
          ...?change.before?.keys,
        }) {
          _pulledOverwrites.add((
            table: change.table,
            rowKey: change.rowKey,
            column: column,
          ));
        }
        continue;
      }
      _pulledOverwrites.add((
        table: change.table,
        rowKey: change.rowKey,
        column: null,
      ));
    }
  }

  /// 这条本机提交改动的地方是否都已经被拉取的远端值覆盖；是就不推。
  bool _coveredByPull(List<RevisionChange> changes) {
    if (_pulledOverwrites.isEmpty) return false;
    for (final change in changes) {
      if (_pulledOverwrites.contains((
        table: change.table,
        rowKey: change.rowKey,
        column: null,
      ))) {
        return true;
      }
      if (change.op != ChangeOp.update) continue;
      for (final column in {...?change.after?.keys, ...?change.before?.keys}) {
        if (_pulledOverwrites.contains((
          table: change.table,
          rowKey: change.rowKey,
          column: column,
        ))) {
          return true;
        }
      }
    }
    return false;
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

  String _requestIdFor(RevisionCommit commit, String deviceId) =>
      syncRequestIdFor(
        stored: commit.requestId,
        deviceId: deviceId,
        commitId: commit.id,
      );

  String _baselineRequestId(
    String deviceId,
    int index,
    List<RevisionChange> chunk,
  ) {
    final digest = sha256
        .convert(
          utf8.encode(jsonEncode([for (final change in chunk) change.toRow()])),
        )
        .toString()
        .substring(0, 12);
    return 'b-${deviceId.substring(0, 8)}-$index-$digest';
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
