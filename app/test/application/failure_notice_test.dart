import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/application/failure_notice.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/domain/models/backup_error.dart';

void main() {
  test('原始异常不进入说明，动作、保留状态与下一步都在', () {
    final text = failureNotice(
      StateError("database error sql 'SELECT * FROM message' args [真实的学习内容]"),
      action: '读取学习记录',
      kept: '本机记录没有改动',
      next: '下拉刷新可以再试',
    );

    expect(text, '读取学习记录没有完成，本机记录没有改动。下拉刷新可以再试。');
    expect(text, isNot(contains('database')));
    expect(text, isNot(contains('真实的学习内容')));
  });

  test('已经是给人看的领域错误保留原说明，再补保留状态与下一步', () {
    final text = failureNotice(
      ScheduleConflictException(
        start: DateTime(2026, 11, 11, 19),
        end: DateTime(2026, 11, 11, 20),
        description: '课表“高等数学”',
      ),
      action: '安排学习时间',
      kept: '这次没有写入',
      next: '可以换一个时间再试',
    );

    expect(text, contains('安排与课表“高等数学”冲突'));
    expect(text, contains('这次没有写入。可以换一个时间再试。'));
  });

  test('模型调用只显示按类型归类的说法，不带配置与响应体', () {
    final text = failureNotice(
      const LlmException(LlmFailure.auth, '401 invalid key sk-secret'),
      action: '获取帮助',
      kept: '题目与本地回答已经保存',
      next: '检查设置里的 API Key 与模型名后重试',
    );

    expect(text, contains('模型调用失败（API Key 无效或没有权限）'));
    expect(text, contains('题目与本地回答已经保存'));
    expect(text, isNot(contains('sk-secret')));
    expect(text, isNot(contains('401')));
  });

  test('备份失败保留已经说明的原因，不重复句末标点', () {
    final text = failureNotice(
      const BackupException('数据包版本与当前应用不一致。'),
      action: '恢复数据包',
      kept: '当前库没有改动',
    );

    expect(text, '数据包版本与当前应用不一致，当前库没有改动。');
  });
}
