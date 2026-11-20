import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/application/material_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

MaterialService _service(TestRig rig, {Clock? clock, bool live = false}) =>
    MaterialService(
      materials: MaterialRepository(rig.db, clock: clock ?? systemClock),
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      runtime: testRuntime(live: live ? rig.db.live : null),
    );

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('材料和全部页码在同一事务内导入', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);

    await expectLater(
      service.importMaterial(
        title: '概率论讲义',
        kind: MaterialKind.book,
        pages: const [
          (pageNo: 1, content: '第一页', label: null),
          (pageNo: 0, content: '无效页码', label: null),
        ],
      ),
      throwsArgumentError,
    );
    expect(await selectRows(rig.db, 'material'), isEmpty);
    expect(await selectRows(rig.db, 'material_page'), isEmpty);
  });

  test('同一批导入出现重复页码时整批拒绝，不覆盖前一页', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);

    await expectLater(
      service.importMaterial(
        title: '概率论讲义',
        pages: const [
          (pageNo: 3, content: '先导入的原文', label: null),
          (pageNo: 3, content: '后导入的原文', label: null),
        ],
      ),
      throwsArgumentError,
    );
    expect(await selectRows(rig.db, 'material'), isEmpty);
    expect(await selectRows(rig.db, 'material_page'), isEmpty);
  });

  test('添加一页遇到已有页码时拒绝写入，原正文保持不变', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [(pageNo: 3, content: '已经校对过的原文', label: '条件概率')],
    );

    await expectLater(
      service.addPage(
        materialId: materialId,
        pageNo: 3,
        content: '新粘贴的原文',
        label: null,
      ),
      throwsA(isA<PageNumberTaken>()),
    );
    final pages = await service.pages(materialId);
    expect(pages, hasLength(1));
    expect(pages.single.content, '已经校对过的原文');
    expect(pages.single.label, '条件概率');
  });

  test('按页码范围读取只返回范围内的页', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [
        (pageNo: 1, content: '第一页', label: null),
        (pageNo: 2, content: '第二页', label: null),
        (pageNo: 3, content: '第三页', label: null),
      ],
    );

    final pages = await MaterialRepository(rig.db)
        .pagesBetween(materialId, pageFrom: 2, pageTo: 3);

    expect(pages.map((page) => page.pageNo), [2, 3]);
    expect((await service.page(materialId, 2))?.content, '第二页');
    expect(await service.page(materialId, 9), isNull);
  });

  test('更正一页在提交历史里保留修改前后的整行', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [(pageNo: 3, content: '旧原文 P(A|B)', label: '条件概率')],
    );
    final page = (await service.pages(materialId)).single;

    await service.correctPage(page: page, corrected: '新原文 P(A∩B)');

    final pages = await service.pages(materialId);
    expect(pages.single.content, '新原文 P(A∩B)');
    final commit = (await rig.engine.undoableCommits(rig.db.raw)).first;
    expect(commit.action, '更正材料页');
    expect(commit.actor, 'user');
    final changes = await rig.engine.changesFor(rig.db.raw, commit.id);
    final change = changes.singleWhere((item) => item.table == 'material_page');
    expect(change.op, ChangeOp.update);
    expect(change.before?['content']?.value, '旧原文 P(A|B)');
    expect(change.after?['content']?.value, '新原文 P(A∩B)');
  });

  test('更正一页返回提交编号，撤销后原文恢复、材料时间写成撤销时刻', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    var tick = 0;
    DateTime clock() => DateTime(2026, 11, 10, 12, 0, tick++);
    final service = _service(rig, clock: clock);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [(pageNo: 3, content: '旧原文 P(A|B)', label: '条件概率')],
    );
    final page = (await service.pages(materialId)).single;
    final materialBefore = await service.byId(materialId);

    final correctResult = await service.correctPage(
      page: page,
      corrected: '新原文 P(A∩B)',
    );

    expect(correctResult.commitId, isNotNull);
    final commitId = correctResult.commitId!;
    final changes = await rig.engine.changesFor(rig.db.raw, commitId);
    expect(
      changes.map((change) => change.table),
      containsAll(['material', 'material_page']),
    );

    final result = await rig.revisions.undoCommit(commitId);

    expect(result.applied, isTrue, reason: result.message);
    final restored = (await service.pages(materialId)).single;
    expect(restored.content, '旧原文 P(A|B)');
    expect(restored.label, '条件概率');
    // 维护列不写回旧值：材料行的 updated_at 写成撤销时刻，不再等于更正前的值。
    final updatedBefore = materialBefore?.updatedAt;
    final updatedAfter = (await service.byId(materialId))?.updatedAt;
    expect(updatedAfter, isNot(updatedBefore));
    expect(updatedAfter!.isAfter(updatedBefore!), isTrue);
  });

  test('内容没有变化时不形成提交，也不留下撤销回执', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [(pageNo: 3, content: '旧原文', label: '条件概率')],
    );
    final page = (await service.pages(materialId)).single;
    final before = await rig.engine.headId(rig.db.raw);

    final result = await service.correctPage(page: page, corrected: '旧原文');

    expect(result.changed, isFalse);
    expect(result.skippedReason, isNotNull);
    expect(await rig.engine.headId(rig.db.raw), before);
  });

  test('更正之后又改过时拒绝撤销，当前原文保持不变', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    var tick = 0;
    DateTime clock() => DateTime(2026, 11, 10, 12, 0, tick++);
    final service = _service(rig, clock: clock);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [(pageNo: 3, content: '旧原文', label: null)],
    );
    final page = (await service.pages(materialId)).single;
    final commitId = (await service.correctPage(
      page: page,
      corrected: '第一次更正',
    )).commitId!;
    final corrected = (await service.pages(materialId)).single;
    await service.correctPage(page: corrected, corrected: '第二次更正');

    final result = await rig.revisions.undoCommit(commitId);

    expect(result.applied, isFalse);
    expect(result.message, contains('又被修改'));
    expect((await service.pages(materialId)).single.content, '第二次更正');
  });

  test('材料详情按页读到更正记录与是否已撤销', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    var tick = 0;
    DateTime clock() => DateTime(2026, 11, 10, 12, 0, tick++);
    final service = _service(rig, clock: clock);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [(pageNo: 3, content: '旧原文', label: null)],
    );
    final page = (await service.pages(materialId)).single;
    final first = (await service.correctPage(
      page: page,
      corrected: '第一次更正',
    )).commitId!;
    final corrected = (await service.pages(materialId)).single;
    final second = (await service.correctPage(
      page: corrected,
      corrected: '第二次更正',
    )).commitId!;

    final history = await rig.revisions.rowHistory(
      table: 'material_page',
      rowKey: page.id,
    );
    expect(history.map((commit) => commit.id), [second, first]);
    expect(
      await rig.revisions.activeCommits(history.map((commit) => commit.id)),
      {first, second},
    );

    final result = await rig.revisions.undoCommit(second);
    expect(result.applied, isTrue, reason: result.message);
    final after = await rig.revisions.rowHistory(
      table: 'material_page',
      rowKey: page.id,
    );
    expect(after.map((commit) => commit.id), contains(first));
    expect(
      await rig.revisions.activeCommits(after.map((commit) => commit.id)),
      isNot(contains(second)),
    );
  });

  test('更正不存在的一页时拒绝写入', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);
    final materialId = await service.create(title: '概率论讲义');

    await expectLater(
      service.correctPage(
        page: MaterialPage(
          id: 'page-999',
          materialId: materialId,
          pageNo: 1,
          content: '旧原文',
        ),
        corrected: '新原文',
      ),
      throwsStateError,
    );
    expect(await selectRows(rig.db, 'material_page'), isEmpty);
  });

  test('材料列表、材料行与页码的订阅在写入之后重读', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig, live: true);
    final materialId = await service.importMaterial(
      title: '概率论讲义',
      pages: const [
        (pageNo: 1, content: '第一页', label: null),
        (pageNo: 2, content: '第二页', label: null),
      ],
    );

    final lists = <List<Material>>[];
    final rows = <Material?>[];
    final pages = <List<MaterialPage>>[];
    final singlePages = <MaterialPage?>[];
    final subscriptions = [
      service.watchList().listen(lists.add),
      service.watchMaterial(materialId).listen(rows.add),
      service.watchPages(materialId).listen(pages.add),
      service.watchPage(materialId, 2).listen(singlePages.add),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });
    await _settle();
    expect(lists.single.single.pageCount, 2);
    expect(rows.single?.title, '概率论讲义');
    expect(pages.single.map((page) => page.pageNo), [1, 2]);
    expect(singlePages.single?.content, '第二页');

    // 补一页之后，整份页码与单页原文都跟着重读。
    await service.addPage(materialId: materialId, pageNo: 3, content: '补充的第三页');
    await _settle();
    expect(pages.last.map((page) => page.pageNo), [1, 2, 3]);
    expect(lists.last.single.pageCount, 3);
    // 按表通知不区分行，补别的页也会让这一页重读一次，结果仍是第 2 页。
    expect(singlePages, hasLength(2));
    expect(singlePages.last?.content, '第二页');

    // 改第 2 页之后，单页读法读到更正后的原文。
    await service.correctPage(
      page: pages.last.singleWhere((page) => page.pageNo == 2),
      corrected: '更正后的第二页',
    );
    await _settle();
    expect(singlePages.last?.content, '更正后的第二页');
    expect(
      pages.last.singleWhere((page) => page.pageNo == 2).content,
      '更正后的第二页',
    );
  });
}
