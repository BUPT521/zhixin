import '../domain/models/revision_models.dart';
import '../data/revisions/revision_service.dart';
import 'time_policy_controller.dart';

/// 撤销的应用层入口：数据层只回放改动，撤销成功之后在这里刷新时间口径。
///
/// 撤销“修改每日截止小时”会写回旧的截止小时；不重新读取的话，设置页与归属日
/// 继续使用缓存值。数据层不依赖 application，刷新因此放在调用方这一层，提交
/// 服务不再接收 `onUndoApplied` 回调。
class UndoService {
  UndoService({required this.revisions, required this.timePolicy});

  final RevisionService revisions;
  final TimePolicyController timePolicy;

  /// 撤销一条提交；真正写回数据之后才刷新截止小时，失败时不刷新。
  Future<RevisionUndoResult> undoCommit(int commitId) async {
    final result = await revisions.undoCommit(commitId);
    if (result.applied) await timePolicy.refresh();
    return result;
  }
}
