/// 材料、页码与引用（01 `material`、`material_page`）。
library;

import '../rules/search_terms.dart';

typedef MaterialPageDraft = ({int pageNo, String content, String? label});

bool isDocxFile(String? name) => name?.toLowerCase().endsWith('.docx') ?? false;

String materialPosition(int? from, {int? to, bool isDocx = false}) {
  final first = from ?? to;
  if (first == null) return '';
  final position = to == null || to == first ? '$first' : '$first–$to';
  return isDocx ? '第 $position 个片段' : '第 $position 页';
}

/// 一份可以按页引用的材料。
class Material {
  const Material({
    required this.id,
    required this.title,
    this.kind = 'text',
    this.sourceRef,
    this.sourceFileName,
    this.goalId,
    this.pageCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory Material.fromRow(Map<String, Object?> row) {
    return Material(
      id: row['id']! as int,
      title: row['title']! as String,
      kind: (row['kind'] as String?) ?? 'text',
      sourceRef: row['source_ref'] as String?,
      sourceFileName: row['source_file_name'] as String?,
      goalId: row['goal_id'] as int?,
      pageCount: (row['page_count'] as int?) ?? 0,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
    );
  }

  final int id;
  final String title;

  /// `text` / `slides` / `book` / `other`。
  final String kind;
  final String? sourceRef;
  final String? sourceFileName;
  final int? goalId;
  final int pageCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get kindLabel => switch (kind) {
    'slides' => '课件',
    'book' => '教材',
    'text' => '文字材料',
    _ => '其他',
  };

  String get label => sourceRef == null ? title : '$title · $sourceRef';

  bool get isDocx => isDocxFile(sourceFileName);

  String position(int? from, {int? to}) =>
      materialPosition(from, to: to, isDocx: isDocx);
}

/// 添加一页时页码已被占用；已有原文不覆盖，改动走更正入口。
class PageNumberTaken implements Exception {
  const PageNumberTaken(this.pageNo);

  final int pageNo;

  @override
  String toString() => '第 $pageNo 页已有原文';
}

/// 材料的一页；页码从 1 开始，作为引用的位置。
class MaterialPage {
  const MaterialPage({
    required this.id,
    required this.materialId,
    required this.pageNo,
    required this.content,
    this.label,
  });

  factory MaterialPage.fromRow(Map<String, Object?> row) {
    return MaterialPage(
      id: row['id']! as int,
      materialId: row['material_id']! as int,
      pageNo: row['page_no']! as int,
      label: row['label'] as String?,
      content: row['content']! as String,
    );
  }

  final int id;
  final int materialId;
  final int pageNo;
  final String? label;
  final String content;

  (int, int) get pageKey => (materialId, pageNo);

  String get preview {
    final text = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 60) return text;
    return '${text.substring(0, 60)}…';
  }
}

/// 检索到的一页材料，带材料标题，供回答引用与补齐内容。
class MaterialHit {
  const MaterialHit({
    required this.materialId,
    required this.materialTitle,
    required this.pageNo,
    required this.content,
    this.label,
    this.snippetText,
    this.isDocx = false,
  });

  factory MaterialHit.fromRow(Map<String, Object?> row) {
    return MaterialHit(
      materialId: row['material_id']! as int,
      materialTitle: (row['material_title'] as String?) ?? '材料',
      pageNo: row['page_no']! as int,
      label: row['label'] as String?,
      content: row['content']! as String,
      isDocx: isDocxFile(row['source_file_name'] as String?),
    );
  }

  final int materialId;
  final String materialTitle;
  final int pageNo;
  final String? label;
  final String content;
  final String? snippetText;
  final bool isDocx;

  String get position => materialPosition(pageNo, isDocx: isDocx);

  (int, int) get pageKey => (materialId, pageNo);

  String get snippet =>
      snippetText ?? searchSnippet(content, const <String>[], limit: 80);
}

/// 一条引用；`verified` 表示 quote 能否在对应页里逐字找到。
class Citation {
  const Citation({
    required this.materialId,
    required this.pageNo,
    required this.quote,
    required this.verified,
    this.materialTitle,
    this.isDocx = false,
  });

  factory Citation.fromJson(
    Object? value, {
    Map<int, String> materialTitles = const {},
  }) {
    if (value is! Map) {
      return const Citation(
        materialId: 0,
        pageNo: 0,
        quote: '',
        verified: false,
      );
    }
    final materialId = value['material_id'];
    final pageNo = value['page_no'];
    final quote = value['quote'];
    return Citation(
      materialId: materialId is int ? materialId : 0,
      pageNo: pageNo is int ? pageNo : 0,
      quote: quote is String ? quote.trim() : '',
      verified: value['verified'] == true,
      isDocx: value['is_docx'] == true,
      materialTitle:
          (value['material_title'] as String?) ?? materialTitles[materialId],
    );
  }

  final int materialId;
  final int pageNo;
  final String quote;
  final bool verified;
  final String? materialTitle;
  final bool isDocx;

  Map<String, Object?> toJson() => {
    'material_id': materialId,
    'page_no': pageNo,
    'quote': quote,
    'verified': verified,
    if (isDocx) 'is_docx': true,
    if (materialTitle != null) 'material_title': materialTitle,
  };

  String get place {
    final title = materialTitle == null ? '材料' : '《${materialTitle!}》';
    return '$title ${materialPosition(pageNo, isDocx: isDocx)}';
  }
}
