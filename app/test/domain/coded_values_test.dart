import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';
import 'package:zhixin/domain/rules/coded_enum.dart';
import 'package:zhixin/domain/rules/notices.dart';

/// 可按值读回的枚举都走同一套断言：值唯一、往返一致、未知值回落 unknown。
void expectRoundTrip<T extends CodedEnum>({
  required List<T> values,
  required T unknown,
  required T Function(String?) fromValue,
}) {
  expect(
    values.map((value) => value.value).toSet(),
    hasLength(values.length),
    reason: '每个枚举值只能出现一次',
  );
  for (final value in values) {
    expect(fromValue(value.value), value, reason: '${value.value} 应读回同一个枚举');
    expect(value.label, isNotEmpty, reason: '${value.value} 要有界面说法');
  }
  expect(fromValue(null), unknown, reason: '空值回落到未知值');
  expect(fromValue('not-a-value'), unknown, reason: '认不出的值回落到未知值');
}

void main() {
  test('目标、事项与计划状态的未知值回落到状态未知', () {
    expectRoundTrip(
      values: LearningGoalStatus.values,
      unknown: LearningGoalStatus.unknown,
      fromValue: LearningGoalStatus.fromValue,
    );
    expectRoundTrip(
      values: PlanItemStatus.values,
      unknown: PlanItemStatus.unknown,
      fromValue: PlanItemStatus.fromValue,
    );
    expectRoundTrip(
      values: StudyPlanStatus.values,
      unknown: StudyPlanStatus.unknown,
      fromValue: StudyPlanStatus.fromValue,
    );
  });

  test('记忆的类型、来源与状态各自回落到未知值，不再借别的值顶上', () {
    expectRoundTrip(
      values: MemoryKind.values,
      unknown: MemoryKind.unknown,
      fromValue: MemoryKind.fromValue,
    );
    expectRoundTrip(
      values: MemorySourceKind.values,
      unknown: MemorySourceKind.unknown,
      fromValue: MemorySourceKind.fromValue,
    );
    expectRoundTrip(
      values: MemoryStatus.values,
      unknown: MemoryStatus.unknown,
      fromValue: MemoryStatus.fromValue,
    );
    expect(MemoryKind.fromValue('not-a-value'), isNot(MemoryKind.progress));
    expect(EvidenceKind.fromValue('not-a-value'), isNot(EvidenceKind.message));
  });

  test('来源与判断的未知值回落到未知值，判断来源不再抛异常', () {
    expectRoundTrip(
      values: EvidenceKind.values,
      unknown: EvidenceKind.unknown,
      fromValue: EvidenceKind.fromValue,
    );
    expectRoundTrip(
      values: AssessmentKind.values,
      unknown: AssessmentKind.unknown,
      fromValue: AssessmentKind.fromValue,
    );
    expect(() => AssessmentKind.fromValue('not-a-value'), returnsNormally);
  });

  test('提示状态按值往返，认不出的值返回空', () {
    for (final notice in Notice.values) {
      expect(noticeFromValue(notice.value), notice);
      expect(notice.label, isNotEmpty);
    }
    expect(noticeFromValue('not-a-value'), isNull);
    expect(noticeFromValue(null), isNull);
  });

  test('状态本身仍然带着判断用的语义', () {
    expect(PlanItemStatus.todo.open, isTrue);
    expect(PlanItemStatus.doing.open, isTrue);
    expect(PlanItemStatus.done.open, isFalse);
    expect(PlanItemStatus.unknown.open, isFalse);
    expect(MemoryKind.difficulty.followsContext, isTrue);
    expect(MemoryKind.preference.followsContext, isFalse);
    expect(MemoryKind.unknown.followsContext, isFalse);
  });
}
