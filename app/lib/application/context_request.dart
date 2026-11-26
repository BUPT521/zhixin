import '../domain/models/assessment.dart';
import '../domain/models/buddy_protocol.dart';
import '../domain/models/question.dart';

/// 一次上下文组装的输入；讨论、作答与系统学习都用这一个对象传参。
///
/// 原先 `ContextService.load` 有十四个可选参数，调用点靠顺序与命名各自记忆；
/// 收成一个不可变请求之后，新增字段只需要改这里与组装处，调用点不会漏传。
class ContextRequest {
  const ContextRequest({
    this.question,
    this.attempt,
    this.assessmentRecords = const [],
    this.mode = BuddyMode.chat,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.pageFrom,
    this.pageTo,
    this.conversationId,
    this.routingSessionId,
    this.query = '',
    this.broughtIdentities = const {},
    this.reusedPageKeys = const [],
    this.conversationFocus,
    this.includeEarlier = true,
  });

  final Question? question;
  final Attempt? attempt;
  final List<Assessment> assessmentRecords;
  final BuddyMode mode;
  final String? goalId;
  final String? materialId;
  final int? pageNo;
  final int? pageFrom;
  final int? pageTo;
  final String? conversationId;

  /// 尚未建立讨论时，用于同一组模型请求的路由标识。
  final String? routingSessionId;
  final String query;
  final Set<String> broughtIdentities;

  /// 重试时接续的原轮材料页；按当前位置读取当前保存的原文，取不到的跳过。
  final List<(String, int)> reusedPageKeys;

  final String? conversationFocus;
  final bool includeEarlier;
}
