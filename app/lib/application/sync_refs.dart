part of 'sync_service.dart';

extension SyncNamedRefs on SyncService {
  Future<void> _syncNamedRefs() async {
    final generation = await engine.currentGeneration(database.raw);
    final merge = await _cursors.read(RevisionCursor.syncRefMerge) != null;
    final initial = await account.call((client, token) => client.refs(token));
    _ensureIdentity();
    final hasLocalNames =
        (await engine.refs(database.raw)).isNotEmpty ||
        (await engine.tombstones(database.raw)).isNotEmpty;
    if (initial.isEmpty && !hasLocalNames) {
      if (merge) await _cursors.delete(RevisionCursor.syncRefMerge);
      return;
    }
    final remote = {for (final ref in initial) ref.name: ref};
    final (dirty, tombstones) = await database.transaction((txn) async {
      if (await engine.currentGeneration(txn) != generation) {
        throw const SyncIdentityChanged();
      }
      final local = await engine.refs(txn);
      final reserved = {...remote.keys, ...local.map((ref) => ref.name)};
      final dirty = <RevisionRef>[];
      for (var ref in local.where((item) => item.isDirty)) {
        final cloud = remote[ref.name];
        if (merge &&
            cloud != null &&
            !cloud.isDeleted &&
            cloud.commitUid != ref.commitUid) {
          final name = _availableRefName(ref.name, reserved);
          await deleteRows(
            txn,
            'revision_ref',
            where: 'name = ?',
            whereArgs: [ref.name],
          );
          ref = ref.copyWith(name: name);
          await insertRow(txn, 'revision_ref', ref.toRow());
        }
        dirty.add(ref);
      }
      return (dirty, await engine.tombstones(txn));
    });
    for (final ref in tombstones) {
      _ensureIdentity();
      await account.call(
        (client, token) => client.deleteRef(token, name: ref.name),
      );
    }
    for (final ref in dirty) {
      _ensureIdentity();
      final cloud = remote[ref.name];
      if (cloud?.deletedAt case final deletedAt?) {
        if (ref.updatedAt?.isAfter(deletedAt) != true) continue;
      }
      if (merge &&
          cloud != null &&
          !cloud.isDeleted &&
          cloud.commitUid == ref.commitUid &&
          cloud.note == (ref.note ?? '')) {
        continue;
      }
      await account.call(
        (client, token) => client.putRef(
          token,
          name: ref.name,
          commitUid: ref.commitUid,
          note: ref.note ?? '',
          sourceUpdatedAt: ref.updatedAt,
        ),
      );
    }
    final latest = dirty.isEmpty && tombstones.isEmpty
        ? initial
        : await account.call((client, token) => client.refs(token));
    _ensureIdentity();
    await database.transaction((txn) async {
      if (await engine.currentGeneration(txn) != generation) {
        throw const SyncIdentityChanged();
      }
      for (final ref in tombstones) {
        await deleteRows(
          txn,
          'revision_ref_tombstone',
          where: 'name = ? AND deleted_at = ?',
          whereArgs: [ref.name, ref.toRow()['deleted_at']],
        );
      }
      for (final ref in dirty) {
        await txn.execute(
          "UPDATE revision_ref SET sync_state = 'clean' "
          'WHERE name = ? AND commit_uid = ? AND updated_at = ? AND note IS ?',
          [ref.name, ref.commitUid, ref.toRow()['updated_at'], ref.note],
        );
      }
      await deleteRows(txn, 'revision_ref', where: "sync_state = 'clean'");
      final pendingDeletes = (await engine.tombstones(txn))
          .map((ref) => ref.name)
          .toSet();
      for (final ref in latest) {
        if (ref.isDeleted || pendingDeletes.contains(ref.name)) continue;
        final updated = ref.updatedAt ?? clock();
        await insertRow(
          txn,
          'revision_ref',
          RevisionRef(
            name: ref.name,
            commitUid: ref.commitUid,
            note: ref.note.isEmpty ? null : ref.note,
            createdAt: updated,
            updatedAt: updated,
          ).toRow(),
          ignore: true,
        );
      }
      await RevisionCursors(txn).delete(RevisionCursor.syncRefMerge);
    });
    database.notifyTables({'revision_ref', 'revision_ref_tombstone'});
  }

  String _availableRefName(String base, Set<String> reserved) {
    for (var index = 1; ; index++) {
      final suffix = index == 1 ? '（本机）' : '（本机 $index）';
      final prefix = String.fromCharCodes(
        base.runes.take(RevisionRef.maxNameLength - suffix.runes.length),
      );
      final name = '$prefix$suffix';
      if (reserved.add(name)) return name;
    }
  }
}
