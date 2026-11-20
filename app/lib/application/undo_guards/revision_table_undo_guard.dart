import '../../data/revisions/revision_actions.dart';
import '../../data/revisions/revision_undo.dart';

/// 其余可撤销表：只声明覆盖范围，撤销时只走数据层的通用核对。
///
/// 目标、记忆、每日截止小时与消息里的回执字段按普通写入撤销，没有额外的业务
/// 约束。材料行与作答行只随各自的入口开放：更正材料页会在同一条提交里刷新
/// 材料行的时间，确认作答记忆会把作答的帮助字段与建议一起写回，这两行离开
/// 对应动作时不开放单项撤销。
class RevisionTableUndoGuard implements UndoGuard {
  const RevisionTableUndoGuard();

  @override
  Set<String> get tables => const {
    'learning_goal',
    'memory',
    'message',
    'material_page',
    'profile',
  };

  @override
  Map<String, Set<String>> get actionTables => const {
    correctMaterialPageAction: {'material'},
    confirmAttemptMemoryAction: {'attempt'},
  };

  @override
  Future<String?> check(UndoCheck check) async => null;
}
