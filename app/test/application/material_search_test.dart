import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/material_search.dart';
import 'package:zhixin/application/paged_result.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';

import '../support/test_db.dart';

/// 材料查找的本地规则：命中原因、近似写法与分页顺序。
///
/// 列表、材料详情与材料选择器都读这一份服务，V10 的“同类命中超过 40 条时
/// 每个入口都能翻到最早一条”先在服务层验证分页顺序，界面用例再验证入口。
void main() {
  test('标题、来源、页标签与页内正文各写一种命中原因', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repository = MaterialRepository(rig.db);
    final titleId = await repository.create(title: '概率论讲义');
    final sourceId = await repository.create(
      title: '线性代数讲义',
      sourceRef: '教材第 8 章',
    );
    final labelId = await repository.create(title: '程序设计讲义');
    await repository.addPage(
      materialId: labelId,
      pageNo: 2,
      content: '循环里累加变量的写法。',
      label: '循环结构',
    );
    final contentId = await repository.create(title: '数据结构讲义');
    await repository.addPage(
      materialId: contentId,
      pageNo: 3,
      content: '二叉树的中序遍历按左根右访问。',
    );
    final service = MaterialSearchService(materials: repository);

    final title = await service.searchPage('概率论');
    expect(title.items.single.material.id, titleId);
    expect(title.items.single.reason, '标题命中');

    final source = await service.searchPage('第 8 章');
    expect(source.items.single.material.id, sourceId);
    expect(source.items.single.reason, '来源命中');

    final label = await service.searchPage('循环结构');
    expect(label.items.single.material.id, labelId);
    expect(label.items.single.reason, '第 2 页的标签命中');
    expect(label.items.single.pageNo, 2);

    final content = await service.searchPage('中序遍历');
    expect(content.items.single.material.id, contentId);
    expect(content.items.single.reason, '第 3 页的正文命中');
    expect(content.items.single.snippet, contains('中序遍历'));
  });

  test('近似写法不命中，题号、公式与下划线按原样命中', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repository = MaterialRepository(rig.db);
    final exact = await repository.create(title: '例 3-2：矩阵的主对角线');
    await repository.create(title: '例 3-20：求矩阵的迹');
    final underscore = await repository.create(title: '累加变量 a_b');
    await repository.create(title: '累加变量 a_bc');
    final formula = await repository.create(title: 'f(x) 返回输入的平方');
    final service = MaterialSearchService(materials: repository);

    final numbered = await service.searchPage('例 3-2');
    expect(numbered.items.map((match) => match.material.id), [exact]);

    final underscored = await service.searchPage('a_b');
    expect(underscored.items.map((match) => match.material.id), [underscore]);

    final formulaHits = await service.searchPage('f(x)');
    expect(formulaHits.items.map((match) => match.material.id), [formula]);
  });

  test('同类命中超过 40 条时按材料顺序分页，能翻到最早一条', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    var tick = 0;
    DateTime clock() => DateTime(2026, 11, 10, 12, 0, tick++);
    final repository = MaterialRepository(rig.db, clock: clock);
    final ids = <String>[];
    for (var index = 1; index <= 45; index++) {
      ids.add(
        await repository.create(
          title: '验收材料 ${index.toString().padLeft(2, '0')}',
        ),
      );
    }
    final service = MaterialSearchService(materials: repository);

    final first = await service.searchPage('验收材料');
    expect(first.items, hasLength(kSearchPageSize));
    expect(first.hasMore, isTrue);
    // 最近修改的在前，与材料列表的顺序一致。
    expect(first.items.first.material.id, ids.last);

    final second = await service.searchPage('验收材料', offset: first.nextOffset);
    expect(second.items, hasLength(kSearchPageSize));
    expect(second.hasMore, isTrue);

    final third = await service.searchPage('验收材料', offset: second.nextOffset);
    expect(third.items, hasLength(5));
    expect(third.hasMore, isFalse);
    // 最早创建的一条在最后一页的最后一行。
    expect(third.items.last.material.id, ids.first);

    // 接上之后共 45 条，没有重复也没有漏项。
    final all = first
        .append(second, key: (match) => match.material.id)
        .append(third, key: (match) => match.material.id);
    expect(all.items, hasLength(45));
    expect(all.items.map((match) => match.material.id).toSet(), ids.toSet());
  });

  test('同名材料按目标或材料区分，各占一条命中', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repository = MaterialRepository(rig.db);
    final goals = TaskRepository(rig.db);
    final algebraGoal = await goals.createGoal(title: '线性代数');
    final programmingGoal = await goals.createGoal(title: '程序设计');
    final algebra = await repository.create(title: '复习讲义', goalId: algebraGoal);
    final programming = await repository.create(
      title: '复习讲义',
      goalId: programmingGoal,
    );
    final service = MaterialSearchService(materials: repository);

    final results = await service.searchPage('复习讲义');
    expect(results.items.map((match) => match.material.id).toSet(), {
      algebra,
      programming,
    });
  });

  test('空查询不读库，直接返回空结果', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repository = MaterialRepository(rig.db);
    await repository.create(title: '概率论讲义');
    final service = MaterialSearchService(materials: repository);

    expect((await service.searchPage('   ')).isEmpty, isTrue);
    expect((await service.searchPage('   ')).hasMore, isFalse);
  });
}
