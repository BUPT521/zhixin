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
    required this.email,
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
  final String email;
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
/// 服务端要求它非空且不超过 64 个字符；本地有些命令用 JSON 编码的请求标识做重复
/// 提交判断（例如更正材料页），长度会超过上限，整批推送因此被拒绝。超长或为空时
/// 改用按提交编号生成的稳定标识，同一提交重试时标识不变，服务端的去重照常生效。
String syncRequestIdFor({
  required String? stored,
  required String deviceId,
  required int commitId,
}) {
  final existing = stored?.trim() ?? '';
  if (existing.isNotEmpty && existing.length <= 64) return existing;
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
  bool _disposed = false;

  /// 这次同步开始时的身份代次；切换账号或实例之后进行中的同步据此丢弃结果。
  int? _runEpoch;

  bool get syncing => _running != null;

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
        email: '',
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
    final ownState =
        state != null &&
            state.userId == snapshot.session!.userId &&
            state.serverOrigin == origin
        ? state
        : null;
    final pending = ownState == null
        ? localHead
        : (await revisions.commitsAfter(ownState.pushedThrough))
              .where((commit) => !ownState.remoteLocalIds.contains(commit.id))
              .length;
    return SyncStatus(
      signedIn: true,
      email: snapshot.email,
      autoSync: snapshot.autoSync,
      syncing: syncing,
      pendingCommits: pending,
      localHead: localHead,
      serverHead: ownState?.serverHead,
      needsBootstrap: ownState == null || ownState.pushedThrough > localHead,
      baselineNeedsConfirmation: ownState == null && localHead > 0,
      lastSyncedAt: ownState?.syncedAt,
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
    final ownState =
        state != null &&
            state.userId == snapshot.session!.userId &&
            state.serverOrigin == origin
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

  /// 退出登录、删除账号或清除云端数据之后清掉本机游标。
  Future<void> clearState() => preferences.clearSyncState();

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
      var state = await preferences.syncState();
      final localHead = await engine.headId(database.raw);
      if (state != null &&
          (state.userId != snapshot.session!.userId ||
              state.serverOrigin != origin ||
              state.pushedThrough > localHead)) {
        // 换了账号或实例，或本机数据被清空、换库：游标不再对应本机提交编号。
        await preferences.clearSyncState();
        state = null;
      }
      if (state != null && remoteHead.head < state.serverHead) {
        // 服务端序列被清空过，服务端位置回到 0，需要重新上传基线。
        await preferences.clearSyncState();
        state = null;
      }

      if (state == null) {
        // 首次同步（或服务端被清空后重建）会把本机记录整份上传，必须先确认；
        // 本机没有记录时不需要确认。
        if (localHead > 0 && !confirmBaseline) {
          throw BaselineConfirmationRequired(localHead);
        }
        final boot = await _bootstrap(deviceId, origin);
        pulled += boot.pulled;
        pushed += boot.pushed;
        uploaded += boot.uploaded;
        downloaded += boot.downloaded;
        state = boot.state;
      } else {
        var current = await _pull(
          state: state,
          deviceId: deviceId,
          downloaded: (count) => downloaded += count,
        );
        pulled += current.pulled;
        state = current.state;
        final push = await _push(
          state: state,
          deviceId: deviceId,
          uploaded: (count) => uploaded += count,
          onPulled: (result) {
            pulled += result.pulled;
            downloaded += result.downloaded;
          },
        );
        pushed += push.pushed;
        state = push.state;
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
  Future<
    ({SyncState state, int pulled, int pushed, int uploaded, int downloaded})
  >
  _bootstrap(String deviceId, String origin) async {
    var pulled = 0;
    var downloaded = 0;
    final remoteHead = await account.call(
      (client, token) => client.head(token),
    );
    final localHead = await engine.headId(database.raw);
    var state = SyncState(
      userId: (await account.snapshot()).session!.userId,
      serverOrigin: origin,
      serverHead: 0,
      pushedThrough: localHead,
    );
    if (remoteHead.head > 0) {
      final result = await _pull(
        state: state,
        deviceId: deviceId,
        persist: false,
        downloaded: (count) => downloaded += count,
      );
      pulled = result.pulled;
      state = result.state;
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
            op: 'insert',
            after: entry.value,
          ),
        );
      }
    }
    var pushed = 0;
    var baseSeq = state.serverHead;
    final userId = state.userId;
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
    state = SyncState(
      userId: userId,
      serverOrigin: origin,
      serverHead: baseSeq,
      pushedThrough: headAfterPull,
      syncedAt: clock(),
    );
    await preferences.saveSyncState(state);
    return (
      state: state,
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

  /// 拉取 `state.serverHead` 之后的提交并应用到本机，返回推进后的游标。
  Future<({SyncState state, int pulled, int downloaded})> _pull({
    required SyncState state,
    required String deviceId,
    required void Function(int count) downloaded,
    bool persist = true,
  }) async {
    var current = state;
    var pulled = 0;
    var downloadCount = 0;
    while (true) {
      _ensureIdentity();
      final page = await account.call(
        (client, token) => client.pull(token, after: current.serverHead),
      );
      if (page.commits.isEmpty) {
        current = current.copyWith(serverHead: page.head);
        if (persist) await preferences.saveSyncState(current);
        break;
      }
      final hashes = <String>{};
      for (final commit in page.commits) {
        _ensureIdentity();
        final applied = await _applyRemote(commit);
        hashes.addAll(applied.assetHashes);
        pulled++;
        if (applied.commit != null) {
          current = current.copyWith(
            remoteLocalIds: {...current.remoteLocalIds, applied.commit!.id},
          );
        }
      }
      current = current.copyWith(
        serverHead: page.commits.last.seq ?? page.head,
        syncedAt: clock(),
      );
      _ensureIdentity();
      if (persist) await preferences.saveSyncState(current);
      final fetched = await _downloadAssets(hashes);
      downloadCount += fetched;
      downloaded(fetched);
      if (!page.hasMore) break;
    }
    return (state: current, pulled: pulled, downloaded: downloadCount);
  }

  /// 推送本机游标之后的提交；服务端位置变化时先拉取再重试。
  Future<({SyncState state, int pushed})> _push({
    required SyncState state,
    required String deviceId,
    required void Function(int count) uploaded,
    required void Function(({int pulled, int downloaded}) result) onPulled,
  }) async {
    var current = state;
    for (var attempt = 0; attempt < 3; attempt++) {
      _ensureIdentity();
      final headNow = await account.call((client, token) => client.head(token));
      if (headNow.head != current.serverHead) {
        final pulled = await _pull(
          state: current,
          deviceId: deviceId,
          downloaded: (count) {},
        );
        current = pulled.state;
        onPulled((pulled: pulled.pulled, downloaded: pulled.downloaded));
      }
      final localHead = await engine.headId(database.raw);
      final pending = [
        for (final commit in await revisions.commitsAfter(
          current.pushedThrough,
        ))
          if (!current.remoteLocalIds.contains(commit.id)) commit,
      ];
      if (pending.isEmpty) {
        current = current.copyWith(pushedThrough: localHead);
        _ensureIdentity();
        await preferences.saveSyncState(current);
        return (state: current, pushed: 0);
      }
      final assetHashes = <String>{};
      var pushed = 0;
      try {
        Stream<ServerCommit> payloads() async* {
          for (final commit in pending) {
            final changes = await engine.changesFor(database.raw, commit.id);
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

        await _pushBatches(payloads(), current.serverHead, (head, count) async {
          pushed += count;
          current = current.copyWith(serverHead: head);
          _ensureIdentity();
          await preferences.saveSyncState(current);
        });
      } on ServerProblem catch (error) {
        if (!error.isConflict) rethrow;
        final head = error.extra['head'];
        current = current.copyWith(
          serverHead: head is num ? head.toInt() : current.serverHead,
        );
        _ensureIdentity();
        await preferences.saveSyncState(current);
        continue;
      }
      uploaded(await _uploadAssets(assetHashes));
      current = current.copyWith(
        pushedThrough: localHead,
        remoteLocalIds: {
          for (final id in current.remoteLocalIds)
            if (id > localHead) id,
        },
        syncedAt: clock(),
      );
      _ensureIdentity();
      await preferences.saveSyncState(current);
      return (state: current, pushed: pushed);
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
          op: change.op,
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
    );
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
    op: change.op,
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
