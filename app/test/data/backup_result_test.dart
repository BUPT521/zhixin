import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/data/backup/data_package_service.dart';
import 'package:zhixin/data/backup/data_version_service.dart';
import 'package:zhixin/data/backup/restore_inspection.dart';
import 'package:zhixin/data/backup/restore_point_store.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/domain/models/result.dart';

import '../support/test_db.dart';

DataVersionService _service(TestRig rig) {
  return DataVersionService(
    gate: rig.db.gate,
    revisions: rig.revisions,
    revisionPackages: RevisionPackageService(
      engine: rig.engine,
      assets: rig.engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
    ),
    dataPackages: DataPackageService(
      filesDir: rig.filesDir,
      dbPath: p.join(rig.filesDir, zhixinDbFileName),
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    ),
    restorePoints: RestorePointStore(filesDir: rig.filesDir),
    engine: rig.engine,
    cache: AttachmentCache(filesDir: () => rig.filesDir),
    connection: () => rig.raw,
    database: () => rig.db,
    reopen: () async => rig.raw,
    resetStudyData: () async {},
    markPendingWorkInvalidated: () {},
    notifyDataChanged: () {},
    recordFailure: (error, stack, {required kind}) {},
  );
}

void main() {
  test('预检数据包把可预期的失败放进结果，成功时带回包内规模', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final service = _service(rig);
    final output = File(p.join(rig.filesDir, 'restore.zip'));
    await service.backupRepository(output.path);

    final inspected = await service.inspectRestorePackage(
      await output.readAsBytes(),
    );
    expect(inspected, isA<Success<RestoreInspection>>());
    expect(inspected.valueOrNull!.kind, RestorePackageKind.repository);

    final rejected = await service.inspectRestorePackage(
      Uint8List.fromList([1, 2, 3, 4]),
    );
    expect(rejected, isA<Failure<RestoreInspection>>());
    expect(rejected.failureOrNull!.message, isNotEmpty);
  });

  test('恢复与导入对坏数据包返回失败原因，不抛可预期异常', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final service = _service(rig);
    final broken = Uint8List.fromList([1, 2, 3, 4]);

    final restored = await service.restore(broken);
    expect(restored, isA<Failure<String?>>());
    expect(restored.failureOrNull!.message, contains('数据包'));

    final head = await service.currentHead();
    final imported = await service.importCurrentData(
      broken,
      expectedHead: head,
    );
    expect(imported, isA<Failure<String?>>());
    expect(imported.failureOrNull!.message, isNotEmpty);
  });
}
