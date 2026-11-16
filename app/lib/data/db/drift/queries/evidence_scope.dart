// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import '../../../../domain/models/evidence.dart';
import '../../../../domain/models/evidence_id.dart';
import '../../../vector/vector_index.dart';
import '../app_database.dart';
import '../tables.dart';

/// 检索范围规则的唯一实现：把一次查找的 [EvidenceScope] 变成一条 SQL 条件。
///
/// 生成查询可以直接把表达式放进 `where`（`EvidenceRepository.inScope`）；
/// 四类命中查询要按 FTS5 的 `MATCH`、`bm25()` 与关键字排名取行，生成查询写不出
/// 这些形态，于是把同一个表达式渲染成 SQL 片段与绑定参数拼进手写查询。
/// 两条路径共用这里的判断，不再各自维护一份 SQL 与一份 Dart。
///
/// 返回空表示“不限范围”，调用方不需要附加条件；返回 `Constant(false)` 表示
/// “一条也不放行”，用来表达没有目标归属、也没有带入来源的回答前检索。
class EvidenceScopeRule {
  const EvidenceScopeRule(this.scope);

  final EvidenceScope scope;

  /// 讨论级来源（消息、题目、作答）的范围条件。
  ///
  /// [kind] 是来源种类（`message`、`question`、`answer`），决定本轮带入的来源
  /// 标识作用在哪张表：[messages] 在消息命中里提供 `message` 标识，[attempts]
  /// 在作答命中里提供 `attempt` 标识。
  Expression<bool>? conversation(
    Conversations c, {
    required String kind,
    Messages? messages,
    Attempts? attempts,
  }) {
    switch (scope.origin) {
      case EvidenceOrigin.user:
        return switch (scope.kind) {
          EvidenceScopeKind.all => null,
          EvidenceScopeKind.goal => c.goalId.equals(scope.goalId!),
          EvidenceScopeKind.material => c.materialId.equals(scope.materialId!),
        };
      case EvidenceOrigin.answer:
        final clauses = <Expression<bool>>[];
        if (scope.goalId == null) {
          // 没有目标归属时只放行当前这条讨论；其他无归属讨论不进入候选。
          if (scope.conversationId != null) {
            clauses.add(c.id.equals(scope.conversationId!));
          }
        } else {
          clauses.add(c.goalId.equals(scope.goalId!) | c.goalId.isNull());
        }
        for (final identity in scope.broughtIdentities) {
          final parsed = EvidenceId.tryParse(identity);
          final id = parsed?.primaryId;
          if (id == null) continue;
          switch (parsed!.kind) {
            case 'message':
              if (kind == 'message') {
                clauses.add(messages!.id.equals(id));
              }
            case 'question':
              if (kind == 'question') {
                clauses.add(c.id.equals(id));
              }
            case 'attempt':
              if (kind == 'answer') {
                clauses.add(attempts!.id.equals(id));
              }
          }
        }
        return _anyOf(clauses);
    }
  }

  /// 材料页的范围条件；材料页只看所属材料的目标归属与本轮带入的材料页。
  Expression<bool>? material(Materials m, MaterialPages mp) {
    switch (scope.origin) {
      case EvidenceOrigin.user:
        return switch (scope.kind) {
          EvidenceScopeKind.all => null,
          EvidenceScopeKind.goal => m.goalId.equals(scope.goalId!),
          // 材料范围只放行这份材料的页；比较材料标识，不能按“材料范围一律
          // 放行”处理，否则语义候选会带出其他材料的页。
          EvidenceScopeKind.material => mp.materialId.equals(scope.materialId!),
        };
      case EvidenceOrigin.answer:
        final pages = <Expression<bool>>[];
        for (final identity in scope.broughtIdentities) {
          final parsed = EvidenceId.tryParse(identity);
          if (parsed?.kind != 'material_page') continue;
          final materialId = parsed!.primaryId;
          final pageNo = parsed.pageNo;
          if (materialId == null || pageNo == null) continue;
          pages.add(
            mp.materialId.equals(materialId) & mp.pageNo.equals(pageNo),
          );
        }
        if (scope.goalId == null) {
          // 没有目标归属时只放行本轮带入的材料页；当前页由回答直接给出。
          return pages.isEmpty ? const Constant(false) : _anyOf(pages);
        }
        final clauses = <Expression<bool>>[
          m.goalId.equals(scope.goalId!) | m.goalId.isNull(),
          ...pages,
        ];
        return _anyOf(clauses);
    }
  }

  /// 把 [clauses] 用 `OR` 连起来；为空时一条也不放行。
  static Expression<bool> _anyOf(List<Expression<bool>> clauses) {
    if (clauses.isEmpty) return const Constant(false);
    var result = clauses.first;
    for (final clause in clauses.skip(1)) {
      result = result | clause;
    }
    return result;
  }
}

/// 把范围表达式渲染成 SQL 片段与按 `?` 顺序排列的绑定值。
///
/// 只在 `.drift` 生成查询表达不了的命中查询里使用，见 [EvidenceScopeRule]。
({String sql, List<Object> values})? renderInSql(
  DatabaseConnectionUser db,
  Expression<bool>? expression,
) {
  if (expression == null) return null;
  final context = GenerationContext.fromDb(db)..hasMultipleTables = true;
  expression.writeInto(context);
  return (sql: context.sql, values: context.boundVariables.cast<Object>());
}

/// 把检索范围变成语义索引可以下推的预过滤；返回空表示不预过滤。
///
/// 只使用写入后不会改变的属性：材料页所属材料、消息与作答所属讨论、来源键。
/// 目标归属可以在之后修改，写进索引会过期，所以限定目标时不预过滤。预过滤
/// 只会放宽：[hitInScope] 判为在范围内的来源在两侧实现里都必须被放行。
VectorPrefilter? vectorPrefilterFor(EvidenceScope scope) {
  if (scope.isUserSearch) {
    return switch (scope.kind) {
      EvidenceScopeKind.all => null,
      EvidenceScopeKind.goal => null,
      EvidenceScopeKind.material => MaterialVectorPrefilter(scope.materialId!),
    };
  }
  // 回答前检索没有目标归属时只放行当前讨论与本轮带入的来源；有目标归属时
  // 没有可下推的条件，交给业务库按目标与无归属判断。
  if (scope.goalId != null) return null;
  return ConversationVectorPrefilter(
    conversationId: scope.conversationId,
    sourceKeys: {
      for (final identity in scope.broughtIdentities)
        if (identity.isNotEmpty) identity,
    },
  );
}

/// 这条命中是否仍在给定范围内：用 [EvidenceScopeRule] 与记录本身的编号核对。
///
/// 语义索引会落后于业务库，调用方在使用索引结果之前必须过这一关。这里把规则
/// 放进生成查询的 `where`，与四类命中查询渲染出的 SQL 片段是同一份判断。
Future<bool> hitInScope(
  AppDatabase db,
  EvidenceHit hit,
  EvidenceScope scope,
) async {
  final rule = EvidenceScopeRule(scope);
  switch (hit.kind) {
    case EvidenceKind.materialPage:
      final materialId = hit.location.materialId;
      final pageNo = hit.location.pageNo;
      if (materialId == null || pageNo == null) return false;
      final material = db.materials;
      final page = db.materialPages;
      final query = db.selectOnly(page)
        ..join([innerJoin(material, material.id.equalsExp(page.materialId))])
        ..addColumns([page.materialId])
        ..where(
          page.materialId.equals(materialId) &
              page.pageNo.equals(pageNo) &
              (rule.material(material, page) ?? const Constant(true)),
        )
        ..limit(1);
      return (await query.get()).isNotEmpty;
    case EvidenceKind.message:
      final messageId = hit.location.messageId;
      if (messageId == null) return false;
      final conversation = db.conversations;
      final message = db.messages;
      final query = db.selectOnly(message)
        ..join([
          innerJoin(
            conversation,
            conversation.id.equalsExp(message.conversationId),
          ),
        ])
        ..addColumns([message.id])
        ..where(
          message.id.equals(messageId) &
              (rule.conversation(
                    conversation,
                    kind: 'message',
                    messages: message,
                  ) ??
                  const Constant(true)),
        )
        ..limit(1);
      return (await query.get()).isNotEmpty;
    case EvidenceKind.question:
      final conversationId = hit.location.conversationId;
      if (conversationId == null) return false;
      final conversation = db.conversations;
      final query = db.selectOnly(conversation)
        ..addColumns([conversation.id])
        ..where(
          conversation.id.equals(conversationId) &
              (rule.conversation(conversation, kind: 'question') ??
                  const Constant(true)),
        )
        ..limit(1);
      return (await query.get()).isNotEmpty;
    case EvidenceKind.answer:
      final attemptId = hit.location.attemptId;
      if (attemptId == null) return false;
      final conversation = db.conversations;
      final attempt = db.attempts;
      final query = db.selectOnly(attempt)
        ..join([
          innerJoin(
            conversation,
            conversation.id.equalsExp(attempt.conversationId),
          ),
        ])
        ..addColumns([attempt.id])
        ..where(
          attempt.id.equals(attemptId) &
              (rule.conversation(
                    conversation,
                    kind: 'answer',
                    attempts: attempt,
                  ) ??
                  const Constant(true)),
        )
        ..limit(1);
      return (await query.get()).isNotEmpty;
    case EvidenceKind.unknown:
      return false;
  }
}
