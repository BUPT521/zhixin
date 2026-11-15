import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/backup_error.dart';
import 'package:zhixin/domain/models/result.dart';
import 'package:zhixin/domain/rules/notices.dart';

void main() {
  test('成功结果带值，失败结果带原因', () {
    const Result<int> success = Success(3);
    expect(success.isSuccess, isTrue);
    expect(success.valueOrNull, 3);
    expect(success.failureOrNull, isNull);

    const Result<int> failure = Failure(FailureReason('已经有的记录没有改动。'));
    expect(failure.isSuccess, isFalse);
    expect(failure.valueOrNull, isNull);
    expect(failure.failureOrNull!.message, '已经有的记录没有改动。');
  });

  test('失败原因可以带回答提示或模型失败类型名', () {
    const reason = FailureReason(
      '模型调用失败',
      notice: Notice.modelCallFailed,
      failureName: 'timeout',
    );
    expect(reason.notice, Notice.modelCallFailed);
    expect(reason.failureName, 'timeout');
  });

  test('可预期的备份失败转成失败原因时保留说明与诊断细节', () {
    final reason = FailureReason.backup(
      const BackupException('数据包校验失败，原数据未改动。', detail: 'FormatException'),
    );
    expect(reason.message, '数据包校验失败，原数据未改动。');
    expect(reason.detail, 'FormatException');
    expect(reason.notice, isNull);
  });
}
