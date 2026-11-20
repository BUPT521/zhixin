import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/time_policy_controller.dart';
import 'package:zhixin/application/undo_service.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';

import '../support/test_db.dart';

void main() {
  test('撤销截止小时后重新读取设置，数据代次推进一次', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    var version = 0;
    final controller = TimePolicyController(
      settings: SettingsRepository(rig.db),
      clock: () => DateTime(2026, 11, 10, 12),
      onChanged: () => version++,
    );
    await controller.refresh();
    expect(controller.cutoffHour, 4);

    await rig.db.command((txn) async {
      await updateRow(txn, 'profile', {
        'day_cutoff_hour': 6,
        'updated_at': '2026-11-10T12:00:00',
      }, where: 'id = 1');
    }, label: changeCutoffHourAction);
    await controller.refresh();
    expect(controller.cutoffHour, 6);
    expect(version, 1);

    final undone = await UndoService(
      revisions: rig.revisions,
      timePolicy: controller,
    ).undoCommit(await rig.engine.headId(rig.raw));
    expect(undone.applied, isTrue, reason: undone.message);
    expect(controller.cutoffHour, 4);
    expect(version, 2);
  });

  test('撤销没有生效时不重新读取设置', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    var version = 0;
    final controller = TimePolicyController(
      settings: SettingsRepository(rig.db),
      clock: () => DateTime(2026, 11, 10, 12),
      onChanged: () => version++,
    );
    await controller.refresh();

    // 找不到的提交不产生变化，时间口径保持原样。
    final undone = await UndoService(
      revisions: rig.revisions,
      timePolicy: controller,
    ).undoCommit(9999);
    expect(undone.applied, isFalse);
    expect(controller.cutoffHour, 4);
    expect(version, 0);
  });
}
