import '../../data/revisions/revision_actions.dart';
import '../../data/revisions/revision_undo.dart';

/// 其余可撤销表：只声明覆盖范围，撤销时只走数据层的通用核对。
///
/// 目标、记忆与消息里的回执字段按普通写入撤销，没有额外的业务约束；每日截止
/// 小时并进 `app_meta` 之后不再单独登记，它随设置项一起按普通写入处理。材料行
/// 与作答行只随各自的入口开放：更正材料页会在同一条提交里刷新材料行的时间，
/// 确认作答记忆会把作答的帮助字段与建议一起写回，这两行离开对应动作时不开放
/// 单项撤销。
class RevisionTableUndoGuard implements UndoGuard {
  const RevisionTableUndoGuard();

  @override
  Set<String> get tables => const {
    'learning_goal',
    'memory',
    'message',
    'material_page',
  };

  @override
  Map<String, Set<String>> get actionTables => const {
    correctMaterialPageAction: {'material'},
    confirmAttemptMemoryAction: {'attempt'},
  };

  @override
  Future<String?> check(UndoCheck check) async => null;
}
