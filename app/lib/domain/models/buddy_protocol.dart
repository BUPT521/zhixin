import '../rules/content_identity.dart' as identity;
import 'assessment.dart';
import 'conversation.dart';
import 'evidence.dart';
import 'material.dart';
import 'memory.dart';
import 'question.dart';
import 'study.dart';
import 'study_plan.dart';

enum BuddyMode {
  chat('chat'),
  hint('hint'),
  explain('explain'),
  check('check'),
  plan('plan');

  const BuddyMode(this.value);

  final String value;
}

/// 本轮补搜入口：只按当前范围改写查询，返回最多 [limit] 条命中。
typedef SourceSearch = Future<List<EvidenceHit>> Function(
  String query,
  int limit,
);

/// 生成回答所需的上下文；只放当前用得到的内容，不发整库。
class BuddyContext {
  const BuddyContext({
    required this.now,
    this.goal,
    this.goals = const [],
    this.openItems = const [],
    this.todayBlocks = const [],
    this.recentAttempts = const [],
    this.memories = const [],
    this.priorFeedback = const [],
    this.question,
    this.attempt,
    this.assessmentRecords = const [],
    this.mode = BuddyMode.chat,
    this.material,
    this.materialPage,
    this.outlinePages = const [],
    this.materialHits = const [],
    this.relatedRecords = const [],
    this.evidence = const [],
    this.crossSessionNotes = const [],
    this.conversationFocus,
    this.sourceSearch,
  });

  final DateTime now;

  /// 当前讨论明确选择的目标；为空表示这次求助没有归属。
  final LearningGoal? goal;

  /// 同时有效的其他目标，只用于让回答知道背景，不替用户归类。
  final List<LearningGoal> goals;
  final List<PlanItem> openItems;
  final List<ScheduledItem> todayBlocks;
  final List<AttemptWithQuestion> recentAttempts;
  final List<Memory> memories;

  /// 同一道题以前提交过的困难，只在再次作答或求助时带入这几条。
  final List<Attempt> priorFeedback;
  final Question? question;
  final Attempt? attempt;
  final List<Assessment> assessmentRecords;

  final BuddyMode mode;

  /// 本次讨论带入的材料与页码；为空表示没有带入材料。
  final Material? material;
  final MaterialPage? materialPage;

  /// 系统学习时一次给出的材料范围，按页码排列。
  final List<MaterialPage> outlinePages;

  /// 按当前问题检索到的其他材料页，用于补充必要内容或引用。
  final List<MaterialHit> materialHits;

  /// 较早的相关讨论，只带入同一目标或同样无归属的记录。
  final List<RelatedRecord> relatedRecords;

  /// 本轮补搜；为空表示这次请求不开放补搜。
  final SourceSearch? sourceSearch;

  /// 本次范围里的字面命中（题号、公式、原句），每条都带来源标识与位置。
  final List<EvidenceHit> evidence;

  /// 跨次综合时缺少的证据或未说明的独立性；回答需要说明这些内容待确认。
  final List<String> crossSessionNotes;
  final String? conversationFocus;

  Iterable<MaterialPage> get uniqueOutlinePages =>
      identity.uniqueById(outlinePages, (page) => page.pageKey);

  Iterable<MaterialHit> get additionalMaterialHits sync* {
    final included = <(int, int)>{
      if (material != null) ?materialPage?.pageKey,
      for (final page in outlinePages) page.pageKey,
    };
    for (final hit in materialHits) {
      if (included.add(hit.pageKey)) yield hit;
    }
  }

  bool get hasQuestion => question != null;
  bool get hasMaterial => materialPage != null;
}

/// 模型被要求返回的结构：一段回答，外加可选的记忆、引用与下一步建议。
class BuddyReply {
  const BuddyReply({
    required this.text,
    this.memories = const [],
    this.nextSteps = const [],
    this.citations = const [],
    this.studySteps = const [],
    this.assessment,
    this.providedSources = const [],
    this.fromModel = true,
    this.stopped = false,
    this.interrupted = false,
    this.interruptedReason,
    this.truncated = false,
  });

  final String text;

  /// 用户在生成过程中点了停止；[text] 是停下时已经显示的部分。
  final bool stopped;

  /// 生成在正文已经显示之后中断；[text] 是中断前已经显示的部分，工具调用已经丢弃。
  final bool interrupted;

  /// 中断原因的人话说明，只用于界面提示，不保存进记录。
  final String? interruptedReason;

  /// 模型因输出上限结束；[text] 是已经生成的部分，工具调用已经丢弃。
  final bool truncated;
  final List<MemoryDraft> memories;
  final List<NextStepDraft> nextSteps;
  final List<CitationDraft> citations;
  final List<StudyStepDraft> studySteps;

  /// 模型给的学习判断；只在用户要求检查时使用。
  final AssessmentDraft? assessment;

  /// 本轮工具真正返回过的材料页原文；引用核验只认这些来源。
  final List<CitationSource> providedSources;
  final bool fromModel;
}

/// 记忆是用户明确说的，还是模型根据记录推断的；两者进入卡片的方式不同。
enum MemorySource {
  user('user'),
  inferred('inferred');

  const MemorySource(this.value);

  final String value;
}

class MemoryDraft {
  const MemoryDraft({
    required this.kind,
    required this.content,
    this.validUntil,
    this.source = MemorySource.inferred,
  });

  final MemoryKind kind;
  final String content;
  final DateTime? validUntil;
  final MemorySource source;

  String get contentId => identity.contentId('memory', [
    kind.value,
    content.trim(),
    validUntil?.toUtc().toIso8601String(),
    source.value,
  ]);
}

class NextStepDraft {
  const NextStepDraft({
    required this.title,
    this.action,
    this.endCondition,
    this.minutes,
  });

  final String title;
  final String? action;
  final String? endCondition;
  final int? minutes;

  String get contentId => identity.contentId('next-step', [
    title.trim(),
    action?.trim() ?? '',
    endCondition?.trim() ?? '',
    minutes,
  ]);
}

/// 模型给出的引用；是否逐字匹配原文由程序核对。
class CitationDraft {
  const CitationDraft({
    required this.materialId,
    required this.pageNo,
    required this.quote,
  });

  final int materialId;
  final int pageNo;
  final String quote;

  String get contentId =>
      identity.contentId('citation', [materialId, pageNo, quote.trim()]);
}

/// 模型给的学习判断；结论与依据分开保存，不标记是否核对。
class AssessmentDraft {
  const AssessmentDraft({required this.result, this.basis});

  final String result;
  final String? basis;
}
