import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/drift/tables.dart'
    show checkValueSets, memoryKinds, memoryStatuses, memoryUseKinds;
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';

/// 列取值集合只有一份：`tables.dart` 的 [checkValueSets]。
///
/// 表类的 CHECK 约束引用这份常量，建库结果与 01 文档由 `schema_doc_test` 比对。
/// 这里核对建库结果里的字符串值集合与常量逐列相同，并保证没有第二份没有登记
/// 的 CHECK 取值集合；新增或删除取值时三处一起改，测试不会替任何一处兜底。
///
/// 有对应枚举的列再与枚举值比对一次：枚举是领域侧的取值来源，常量是建库侧的
/// 表示，两边顺序与内容都必须相同；`unknown` 的取值为空串，只用于读取回落，
/// 不写进库，因此不参与比对。
void main() {
  late Map<String, Map<String, List<String>>> actual;

  setUpAll(() async {
    final db = AppDatabase.memory();
    try {
      final rows = await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
          )
          .get();
      actual = {
        for (final row in rows)
          row.read<String>('name'): _checkValueSets(row.read<String>('sql')),
      };
    } finally {
      await db.close();
    }
  });

  test('每张表的 CHECK 值集合与 tables.dart 逐列相同', () {
    final found = <String>{};
    for (final table in actual.entries) {
      for (final column in table.value.entries) {
        final key = '${table.key}.${column.key}';
        expect(
          checkValueSets[key],
          column.value,
          reason: '$key 的 CHECK 取值与 checkValueSets 不一致',
        );
        found.add(key);
      }
    }
    expect(
      found,
      checkValueSets.keys.toSet(),
      reason: '有字符串值集合没有登记到 checkValueSets',
    );
  });

  test('有对应枚举的取值集合与枚举值相同', () {
    final enumSets = <String, List<String>>{
      'learning_goal.status': _enumValues<LearningGoalStatus>(
        LearningGoalStatus.values,
        (value) => value.value,
      ),
      'study_plan.status': _enumValues<StudyPlanStatus>(
        StudyPlanStatus.values,
        (value) => value.value,
      ),
      'plan_item.status': _enumValues<PlanItemStatus>(
        PlanItemStatus.values,
        (value) => value.value,
      ),
      'study_session.outcome': _enumValues<SessionOutcome>(
        SessionOutcome.values,
        (value) => value.value,
      ),
      'assessment.kind': _enumValues<AssessmentKind>(
        AssessmentKind.values,
        (value) => value.value,
      ),
      'memory.kind': _enumValues<MemoryKind>(
        MemoryKind.values,
        (value) => value.value,
      ),
      'memory.source_kind': _enumValues<MemorySourceKind>(
        MemorySourceKind.values,
        (value) => value.value,
      ),
      'memory.status': _enumValues<MemoryStatus>(
        MemoryStatus.values,
        (value) => value.value,
      ),
    };
    for (final entry in enumSets.entries) {
      expect(
        checkValueSets[entry.key],
        entry.value,
        reason: '${entry.key} 的常量与枚举取值不一致，改枚举时同步改 tables.dart',
      );
    }
  });

  test('记忆的三分类取值与状态取值固定，旧四类与“已被取代”不再接受', () {
    expect(memoryKinds, ['episodic', 'semantic', 'procedural']);
    expect(memoryStatuses, ['active', 'deleted']);
    for (final legacy in [
      'preference',
      'constraint',
      'difficulty',
      'progress',
    ]) {
      expect(memoryKinds, isNot(contains(legacy)), reason: '旧四类标签不再写进库里');
    }
    expect(memoryStatuses, isNot(contains('superseded')));
    expect(memoryUseKinds, ['recall', 'search']);
  });
}

/// 枚举值集合，去掉只用于读取回落的空串。
List<String> _enumValues<T>(Iterable<T> values, String Function(T) valueOf) => [
  for (final value in values)
    if (valueOf(value).isNotEmpty) valueOf(value),
];

/// 从建表语句里读 `CHECK("列" IN ('值', ...))` 的字符串值集合。
///
/// 只收带引号的字符串值；布尔列的 `IN (0, 1)` 与范围、空值条件不属于值集合。
Map<String, List<String>> _checkValueSets(String sql) {
  final pattern = RegExp(r'CHECK\("(\w+)" IN \(([^)]*)\)\)');
  final sets = <String, List<String>>{};
  for (final match in pattern.allMatches(sql)) {
    final values = RegExp(r"'([^']*)'")
        .allMatches(match.group(2)!)
        .map((value) => value.group(1)!)
        .toList();
    if (values.isEmpty) continue;
    sets[match.group(1)!] = values;
  }
  return sets;
}
