import 'account_service.dart';
import 'sync_service.dart';

/// 同步之前要问用户的一次确认；页面按种类弹对应的确认框，说明文字留在界面。
sealed class SyncConfirmation {
  const SyncConfirmation();
}

/// 整库恢复之后的第一轮同步：云端会改成恢复后的内容。
final class SyncRestoreAlignment extends SyncConfirmation {
  const SyncRestoreAlignment();
}

/// 首次同步：把本机现有的提交上传到这个账号。
final class SyncBaselineUpload extends SyncConfirmation {
  const SyncBaselineUpload(this.localCommits);

  /// 本机现有的提交条数，说明里要写出来。
  final int localCommits;
}

/// 云端历史已经压缩：用云端快照重建本机历史。
final class SyncSnapshotRebuild extends SyncConfirmation {
  const SyncSnapshotRebuild(this.localCommits);

  /// 本机还没有推送、会重放到快照之上的提交条数。
  final int localCommits;
}

/// 一轮同步的结论；取消时写清在哪一步取消，页面据此给下一步说明。
enum SyncOutcome {
  completed,
  cancelledRestoreAlignment,
  cancelledBaselineUpload,
  cancelledSnapshotRebuild,
}

/// [SyncFlow] 的结果：结论、同步计数与结束之后读到的摘要标记。
class SyncFlowResult {
  const SyncFlowResult(this.outcome, {this.result, this.digestMismatch});

  final SyncOutcome outcome;

  /// 跑完的这一次同步的计数；取消时为空。
  final SyncResult? result;

  /// 结束之后读到的“本机与云端不一致”标记；没有跑完同步时为空。
  final bool? digestMismatch;

  bool get cancelled => outcome != SyncOutcome.completed;

  bool get changed => result?.changed ?? false;
}

/// 一轮同步的确认顺序与执行：账号页与“我的”页原先各写一遍，已经出现提示文案与
/// 附件计数的差异（A22）。
///
/// 确认框的说明文字与取消之后的下一步都在界面，所以页面给出 [SyncFlow.run] 的
/// `confirm` 回调；顺序本身（先恢复对齐、再首次基线、最后快照重建，取消基线时
/// 暂停自动同步）只在这里写一份。
class SyncFlow {
  const SyncFlow({required this.account, required this.sync});

  final AccountService account;
  final SyncService sync;

  /// 跑一轮同步。
  ///
  /// 读同步状态失败与同步本身失败都直接抛出，由页面按统一的失败说明提示；用户
  /// 在任一确认框里取消时返回对应的取消结论，本机数据保持不变。
  Future<SyncFlowResult> run({
    required Future<bool> Function(SyncConfirmation confirmation) confirm,
  }) async {
    final status = await sync.status();
    var confirmBaseline = false;
    if (status.restoreNeedsConfirmation) {
      if (!await confirm(const SyncRestoreAlignment())) {
        return const SyncFlowResult(SyncOutcome.cancelledRestoreAlignment);
      }
      confirmBaseline = true;
    } else if (status.baselineNeedsConfirmation) {
      if (!await confirm(SyncBaselineUpload(status.localHead))) {
        // 取消就不上传，并把自动同步停下来；恢复要在开关上再确认一次。
        await account.setAutoSync(false);
        return const SyncFlowResult(SyncOutcome.cancelledBaselineUpload);
      }
      confirmBaseline = true;
    }
    // 云端历史被压缩时同步会抛出 SyncSnapshotProblem（code 为
    // confirmationRequired）：先确认再说明，确认之后带 confirmReclone 再跑一轮，
    // 本机数据不在未确认时被替换（同步方案 3.7）。
    var confirmReclone = false;
    while (true) {
      try {
        final result = await sync.syncNow(
          confirmBaseline: confirmBaseline,
          confirmReclone: confirmReclone,
        );
        return SyncFlowResult(
          SyncOutcome.completed,
          result: result,
          digestMismatch: await sync.digestMismatch(),
        );
      } on SyncSnapshotProblem catch (problem) {
        if (problem.code != SyncSnapshotCode.confirmationRequired) rethrow;
        if (!await confirm(SyncSnapshotRebuild(problem.localCommits))) {
          return const SyncFlowResult(SyncOutcome.cancelledSnapshotRebuild);
        }
        confirmReclone = true;
      }
    }
  }
}

/// 在同步服务上取这一份流程对象：页面从服务上直接拿到，不再自己记确认顺序。
extension SyncFlowAccess on SyncService {
  SyncFlow get flow => SyncFlow(account: account, sync: this);
}
