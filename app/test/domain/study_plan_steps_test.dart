import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/rules/study_plan_steps.dart';

void main() {
  test('进行中的步骤只保留一个：同计划里其他进行中的改回待开始', () {
    final change = studyStepStatusChange(
      PlanItemStatus.doing,
      planId: 'plan-7',
    );
    expect(change.status, PlanItemStatus.doing);
    expect(change.planId, 'plan-7');
    expect(change.resetOtherActive, isTrue);
  });

  test('不属于任何计划的步骤只改自己的状态，不动其他进行中的步骤', () {
    final change = studyStepStatusChange(PlanItemStatus.doing);
    expect(change.resetOtherActive, isFalse);
  });
}
