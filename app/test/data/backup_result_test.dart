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
import 'package:zhixin/data/db/sql.dart';

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
    restorePointStore: RestorePointStore(filesDir: rig.filesDir),
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

  test('数据版本页的整屏读取跟随提交与恢复点删除更新', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final service = _service(rig);
    final store = RestorePointStore(filesDir: rig.filesDir);
    final point = await store.capture(
      head: 0,
      commitCount: 0,
      namedCount: 0,
      reason: '测试恢复点',
      write: (path) => File(path).writeAsBytes([1, 2, 3]),
    );

    final values = <DataVersionOverview>[];
    final subscription = service.watchOverview().listen(values.add);
    addTearDown(subscription.cancel);
    await _waitFor(values, 1);
    expect(values, hasLength(1), reason: '订阅之后先读一次');
    expect(values.single.restorePoints, hasLength(1), reason: '恢复点随这一屏一起读回');
    final headBefore = values.single.history.head;

    // 一次普通写入形成提交：提交收尾通知版本元数据表，整屏重读一次。
    await rig.db.command((txn) async {
      await updateRow(txn, 'profile', {
        'day_cutoff_hour': 6,
        'updated_at': '2026-11-10T12:00:00',
      }, where: 'id = 1');
    }, label: '调整每日截止时间');
    await _waitFor(values, 2);
    expect(values, hasLength(2), reason: '写入之后重读一次');
    expect(values.last.history.head, greaterThan(headBefore));

    // 恢复点在文件里，删除之后由服务按版本表补发一次通知。
    await service.deleteRestorePoint(point);
    await _waitFor(values, 3);
    expect(values, hasLength(3), reason: '删除恢复点之后重读一次');
    expect(values.last.restorePoints, isEmpty);
  });
}

/// 等到订阅收到第 [count] 次结果。
///
/// 通知、读取与回填都是微任务与定时器；整机负载高时固定延时不一定够，
/// 这里按条件等，超时之后由随后的断言报出实际结果。
Future<void> _waitFor(List<Object?> values, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (values.length < count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
