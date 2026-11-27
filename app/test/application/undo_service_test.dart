import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/time_policy_controller.dart';
import 'package:zhixin/application/undo_service.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/domain/rules/revision_actions.dart';

import '../support/test_db.dart';

void main() {
  test('截止小时的提交没有可撤销的数据变化，撤销被拒绝且时间口径不动', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    var version = 0;
    final settings = SettingsRepository(rig.db);
    final controller = TimePolicyController(
      settings: settings,
      clock: () => DateTime(2026, 11, 10, 12),
      onChanged: () => version++,
    );
    await controller.refresh();
    expect(controller.cutoffHour, 4);

    // 截止小时存在 app_meta 的 day_cutoff_hour 键里，这一行不参与版本采集，
    // 但写入脏页形成的提交照常进入历史。
    await rig.db.command((txn) async {
      await settings.setCutoffHour(6, DateTime(2026, 11, 10, 12));
    }, label: changeCutoffHourAction);
    await controller.refresh();
    expect(controller.cutoffHour, 6);
    expect(version, 1);

    final undone = await UndoService(
      revisions: rig.revisions,
      timePolicy: controller,
    ).undoCommit(await rig.engine.headId(rig.raw));
    // app_meta 不参与版本采集，截止小时这次写入的提交在明细里是空的，撤销服务
    // 按“没有可以撤销的数据变化”拒绝，运行时截止小时由保存路径自己重读
    // （SettingsService.saveCutoffHour 保存之后调用 timePolicy.refresh）。
    expect(undone.applied, isFalse);
    expect(undone.message, '找不到要撤销的提交');
    expect(controller.cutoffHour, 6);
    expect(version, 1);
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
