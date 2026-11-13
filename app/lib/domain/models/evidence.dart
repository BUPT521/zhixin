import '../rules/content_identity.dart';

/// 检索命中的来源种类；界面分组、回答引用与范围核对都按它区分。
enum EvidenceKind {
  materialPage('material_page', '材料页'),
  question('question', '题目'),
  answer('answer', '已提交作答'),
  message('message', '讨论消息');

  const EvidenceKind(this.value, this.label);

  final String value;
  final String label;

  static EvidenceKind fromValue(String value) {
    return EvidenceKind.values.firstWhere(
      (kind) => kind.value == value,
      orElse: () => EvidenceKind.message,
    );
  }
}

/// 查找是谁发起的：用户主动查找可以选范围，回答前检索只能使用本次请求的范围。
enum EvidenceOrigin {
  user('user', '用户查找'),
  answer('answer', '回答前检索');

  const EvidenceOrigin(this.value, this.label);

  final String value;
  final String label;
}

/// 用户选择的查找范围。
enum EvidenceScopeKind {
  all('all', '本机全部记录'),
  goal('goal', '一个目标'),
  material('material', '一份材料');

  const EvidenceScopeKind(this.value, this.label);

  final String value;
  final String label;
}

/// 一次查找的适用范围与发起方。
///
/// 用户查找按明确选择的范围执行，默认覆盖本机全部记录；回答前检索由调用方
/// 传入当前目标、材料与讨论，只在对应范围内取候选，两条路径不共用默认范围。
class EvidenceScope {
  const EvidenceScope({
    required this.origin,
    required this.kind,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.conversationId,
    this.broughtIdentities = const {},
  });

  /// 用户在记录页主动查找：默认本机全部记录。
  const EvidenceScope.userAll()
    : origin = EvidenceOrigin.user,
      kind = EvidenceScopeKind.all,
      goalId = null,
      materialId = null,
      pageNo = null,
      conversationId = null,
      broughtIdentities = const {};

  /// 用户主动查找时选定一个目标。
  const EvidenceScope.userGoal(int id)
    : origin = EvidenceOrigin.user,
      kind = EvidenceScopeKind.goal,
      goalId = id,
      materialId = null,
      pageNo = null,
      conversationId = null,
      broughtIdentities = const {};

  /// 用户主动查找时选定一份材料。
  const EvidenceScope.userMaterial(int id)
    : origin = EvidenceOrigin.user,
      kind = EvidenceScopeKind.material,
      goalId = null,
      materialId = id,
      pageNo = null,
      conversationId = null,
      broughtIdentities = const {};

  /// 回答前检索：按当前题目、材料与目标限制候选。
  ///
  /// [broughtIdentities] 是用户从查找结果里点“加入本次回答”带入的来源标识，
  /// 例如 `attempt:12`、`message:88`、`material_page:3:7`。它只对这一次回答
  /// 有效，由调用方逐轮传入，不写进讨论或记录。
  const EvidenceScope.answer({
    this.goalId,
    this.materialId,
    this.pageNo,
    this.conversationId,
    this.broughtIdentities = const {},
  }) : origin = EvidenceOrigin.answer,
       kind = EvidenceScopeKind.all;

  final EvidenceOrigin origin;
  final EvidenceScopeKind kind;
  final int? goalId;
  final int? materialId;

  /// 当前材料页码；跨次综合沿“这份材料页”找作答时使用。
  final int? pageNo;

  /// 当前讨论；回答前检索用它排除本条记录本身的相关消息。
  final int? conversationId;

  /// 本轮由用户从查找结果带入的来源标识，例如 `attempt:12`；没有带入时为空。
  /// 它只对这一次回答有效，由调用方逐轮传入，不写进讨论或记录。
  final Set<String> broughtIdentities;

  bool get isUserSearch => origin == EvidenceOrigin.user;
  bool get isAnswerContext => origin == EvidenceOrigin.answer;
  bool get limitsToAll => kind == EvidenceScopeKind.all && isUserSearch;

  /// 没有目标归属的求助：只读当前讨论与本轮带入的来源。有目标时仍按“同目标
  /// 或无归属”取候选，另外放行本轮带入的来源。
  bool get restrictsToCurrentRecord => isAnswerContext && goalId == null;

  /// 界面上的一句话说明，避免用户以为回答会自动使用全部记录。
  String get label {
    if (isAnswerContext) return '本次回答范围';
    return switch (kind) {
      EvidenceScopeKind.all => '本机全部记录',
      EvidenceScopeKind.goal => '目标：$goalId',
      EvidenceScopeKind.material => '材料：$materialId',
    };
  }
}

/// 命中在业务记录里的位置；界面据此打开原记录。
class EvidenceLocation {
  const EvidenceLocation({
    this.conversationId,
    this.messageId,
    this.materialId,
    this.pageNo,
    this.attemptId,
    this.offset,
  });

  final int? conversationId;
  final int? messageId;
  final int? materialId;
  final int? pageNo;
  final int? attemptId;

  /// 字面命中的起始位置（从 1 开始），用于在原记录里标出这一处。
  final int? offset;
}

/// 一条可核对的检索命中。
///
/// [identity] 是来源标识：同一个业务记录无论由哪条检索路径命中，都得到同一个
/// 标识，合并时据此去重。[sourceVersion] 是命中时的记录版本，语义索引写回与
/// 回答引用前重新读取当前记录，版本不一致就不使用这条命中。
class EvidenceHit {
  const EvidenceHit({
    required this.kind,
    required this.identity,
    required this.title,
    required this.snippet,
    required this.matchedText,
    required this.literal,
    required this.score,
    required this.location,
    this.semantic = false,
    this.sourceVersion,
    this.createdAt,
    this.conversationTitle,
    this.sourceRef,
    this.text = '',
  });

  final EvidenceKind kind;
  final String identity;
  final String title;
  final String snippet;

  /// 逐字命中的原文；字面命中时它与 [snippet] 中的可核对部分一致。
  final String matchedText;
  final bool literal;

  /// 这条命中来自语义检索；关键词与原文命中为假。同一来源同时被两路命中时
  /// 合并保留关键词那条，界面据此只给语义独有的记录加标签。
  final bool semantic;
  final double score;
  final EvidenceLocation location;
  final String? sourceVersion;
  final DateTime? createdAt;
  final String? conversationTitle;
  final String? sourceRef;

  /// 命中的当前原文；界面显示摘要，排序与核对使用完整文本。
  final String text;

  bool get opensDiscussion =>
      location.conversationId != null &&
      (kind == EvidenceKind.message || kind == EvidenceKind.question);
  bool get opensLearning => kind == EvidenceKind.answer;
  bool get opensMaterial => kind == EvidenceKind.materialPage;

  EvidenceHit copyWith({
    bool? literal,
    bool? semantic,
    double? score,
    String? snippet,
    String? sourceVersion,
    EvidenceLocation? location,
  }) {
    return EvidenceHit(
      kind: kind,
      identity: identity,
      title: title,
      snippet: snippet ?? this.snippet,
      matchedText: matchedText,
      literal: literal ?? this.literal,
      semantic: semantic ?? this.semantic,
      score: score ?? this.score,
      location: location ?? this.location,
      sourceVersion: sourceVersion ?? this.sourceVersion,
      createdAt: createdAt,
      conversationTitle: conversationTitle,
      sourceRef: sourceRef,
      text: text,
    );
  }
}

/// 本轮真正提供给模型的材料原文；引用核验只认这些来源与版本。
class CitationSource {
  const CitationSource({
    required this.materialId,
    required this.pageNo,
    required this.content,
    this.materialTitle,
    this.sourceVersion,
    this.isDocx = false,
  });

  final int materialId;
  final int pageNo;
  final String content;
  final String? materialTitle;
  final String? sourceVersion;
  final bool isDocx;

  (int, int) get pageKey => (materialId, pageNo);
}

/// 一次检索的耗时：嵌入、查索引与完整检索分开记录，失败时也能看到停在哪一段。
class EvidenceTimings {
  const EvidenceTimings({
    this.embedMs = 0,
    this.indexMs = 0,
    this.totalMs = 0,
    this.verifiedOut = 0,
    this.candidates = 0,
    this.rankMs = 0,
  });

  final int embedMs;
  final int indexMs;
  final int totalMs;

  /// 因版本、删除或范围变化被排除的候选条数。
  final int verifiedOut;
  final int candidates;

  /// 关键词候选的 BM25 排序耗时。
  final int rankMs;

  Map<String, Object?> toJson() => {
    'embed_ms': embedMs,
    'index_ms': indexMs,
    'total_ms': totalMs,
    'verified_out': verifiedOut,
    'candidates': candidates,
    'rank_ms': rankMs,
  };
}

/// 一次检索的结果；[dropped] 记录因范围、版本或记录已删除而被排除的条数。
class EvidenceBundle {
  const EvidenceBundle({
    required this.query,
    required this.scope,
    this.hits = const [],
    this.dropped = 0,
    this.semanticFailed = false,
    this.timings,
    this.crossSessionNotes = const [],
  });

  final String query;
  final EvidenceScope scope;
  final List<EvidenceHit> hits;
  final int dropped;

  /// 语义检索不可用或超时；调用方继续使用字面与关键词结果。
  final bool semanticFailed;

  /// 语义检索的耗时；没有调用语义检索时为空。
  final EvidenceTimings? timings;

  /// 跨次综合时缺少的证据或未说明的独立性；回答需要说明这些内容待确认。
  final List<String> crossSessionNotes;

  bool get isEmpty => hits.isEmpty;

  /// 按来源标识合并：同一个业务记录只保留一条，字面命中优先。
  static EvidenceBundle merge(
    String query,
    EvidenceScope scope,
    Iterable<EvidenceHit> candidates, {
    int? limit,
    int dropped = 0,
    bool semanticFailed = false,
    EvidenceTimings? timings,
    List<String> crossSessionNotes = const [],
  }) {
    final merged = <String, EvidenceHit>{};
    for (final hit in candidates) {
      final current = merged[hit.identity];
      if (current == null || _better(hit, current)) merged[hit.identity] = hit;
    }
    final sorted = merged.values.toList(growable: false)..sort(_compare);
    final chosen = limit == null || sorted.length <= limit
        ? sorted
        : sorted.sublist(0, limit);
    return EvidenceBundle(
      query: query,
      scope: scope,
      hits: chosen,
      dropped: dropped + (sorted.length - chosen.length),
      semanticFailed: semanticFailed,
      timings: timings,
      crossSessionNotes: crossSessionNotes,
    );
  }

  static bool _better(EvidenceHit candidate, EvidenceHit current) {
    if (candidate.literal != current.literal) return candidate.literal;
    // 同一来源同时被关键词和语义命中时保留关键词那条：它的片段里有用户
    // 输入的词，可以直接核对，语义分数只用来排序。
    if (candidate.semantic != current.semantic) return !candidate.semantic;
    return candidate.score > current.score;
  }

  static int _compare(EvidenceHit left, EvidenceHit right) {
    if (left.literal != right.literal) return left.literal ? -1 : 1;
    final byScore = right.score.compareTo(left.score);
    if (byScore != 0) return byScore;
    final leftTime = left.createdAt?.millisecondsSinceEpoch ?? 0;
    final rightTime = right.createdAt?.millisecondsSinceEpoch ?? 0;
    return rightTime.compareTo(leftTime);
  }
}

/// 记录版本：内容与更新时间一起参与，内容改写或更正之后版本随之改变。
String evidenceSourceVersion(String content, Object? updatedAt) =>
    contentHash('$content\n${updatedAt ?? ''}'.codeUnits);
