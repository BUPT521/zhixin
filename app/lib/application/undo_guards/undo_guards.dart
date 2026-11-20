import '../../data/revisions/revision_undo.dart';
import 'plan_item_undo_guard.dart';
import 'revision_table_undo_guard.dart';
import 'schedule_undo_guard.dart';
import 'timetable_undo_guard.dart';

export 'plan_item_undo_guard.dart';
export 'revision_table_undo_guard.dart';
export 'schedule_undo_guard.dart';
export 'timetable_undo_guard.dart';

/// 应用层注册的撤销业务约束与可撤销表名单。
///
/// 数据层只做通用核对（代次、后续修改、当前值、白名单与消息回执清理），
/// 哪些表可以撤销、撤销前还要满足什么业务条件由这里的 guard 声明与实现；
/// 新增可撤销表时在这里补声明，不改数据层（ADR-0039）。
const List<UndoGuard> defaultUndoGuards = [
  ScheduleUndoGuard(),
  PlanItemUndoGuard(),
  TimetableUndoGuard(),
  RevisionTableUndoGuard(),
];
