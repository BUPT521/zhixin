import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/application/failure_notice.dart';
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/domain/models/backup_error.dart';

void main() {
  test('原始异常不进入说明，动作、保留状态与下一步都在', () {
    final text = failureNotice(
      StateError("database error sql 'SELECT * FROM message' args [真实的学习内容]"),
      action: '读取学习记录',
      kept: '本机记录没有改动',
      next: '可以点重试再试',
    );

    expect(text, '读取学习记录没有完成，本机记录没有改动。可以点重试再试。');
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
      next: '检查登录状态与模型名后重试',
    );

    expect(text, contains('模型调用失败（登录已失效或没有访问权限）'));
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

  test('同步的快照重建与历史压缩说明直接给用户看，不退化成通用失败', () {
    final reclone = failureNotice(
      const RecloneConfirmationRequired(localCommits: 3, snapshotSeq: 40),
      action: '同步',
      kept: '本机数据没有改动',
    );
    expect(reclone, contains('云端历史已经压缩，这台设备要从云端快照重新克隆'));
    expect(reclone, contains('本机还没有推送的 3 条改动'));
    expect(reclone, isNot(contains('同步没有完成')));

    final unavailable = failureNotice(
      const SyncSnapshotUnavailable(),
      action: '同步',
      kept: '本机数据没有改动',
    );
    expect(unavailable, contains('缺少可用快照'));
    expect(unavailable, contains('清除云端数据后重新开始'));

    final compacted = failureNotice(
      const SyncHistoryCompacted(
        earliestSeq: 30,
        head: 40,
        snapshot: ServerSnapshot(
          seq: 30,
          sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          digest: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ),
      action: '同步',
    );
    expect(compacted, contains('要从云端快照重新克隆'));

    final invalid = failureNotice(
      const SyncSnapshotInvalid('摘要对不上'),
      action: '同步',
      kept: '本机数据没有改动',
    );
    expect(invalid, contains('云端快照校验失败'));
  });
}
