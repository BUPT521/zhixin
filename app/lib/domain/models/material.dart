/// 材料、页码与引用（01 `material`、`material_page`）。
library;

import '../rules/coded_enum.dart';
import '../rules/search_terms.dart';

import '../rules/text.dart';

typedef MaterialPageDraft = ({int pageNo, String content, String? label});

/// 材料种类（01 `material.kind`）；界面按 [label] 显示。
enum MaterialKind implements CodedEnum {
  text('text', '文字材料'),
  slides('slides', '课件'),
  book('book', '教材'),
  other('other', '其他'),
  unknown('', '种类未知');

  const MaterialKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static MaterialKind fromValue(String? value) =>
      codedValueOr(MaterialKind.values, value, unknown: unknown);
}

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
    this.kind = MaterialKind.text,
    this.sourceRef,
    this.sourceFileName,
    this.goalId,
    this.pageCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;

  /// 材料种类；读库时认不出的值回落到 [MaterialKind.unknown]。
  final MaterialKind kind;
  final String? sourceRef;
  final String? sourceFileName;
  final String? goalId;
  final int pageCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get kindLabel => kind.label;

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

  final String id;
  final String materialId;
  final int pageNo;
  final String? label;
  final String content;

  (String, int) get pageKey => (materialId, pageNo);

  String get preview {
    final text = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return truncateCodePoints(text, 60);
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

  final String materialId;
  final String materialTitle;
  final int pageNo;
  final String? label;
  final String content;
  final String? snippetText;
  final bool isDocx;

  String get position => materialPosition(pageNo, isDocx: isDocx);

  (String, int) get pageKey => (materialId, pageNo);

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
    Map<String, String> materialTitles = const {},
  }) {
    if (value is! Map) {
      return const Citation(
        materialId: '',
        pageNo: 0,
        quote: '',
        verified: false,
      );
    }
    final materialId = value['material_id'];
    final pageNo = value['page_no'];
    final quote = value['quote'];
    return Citation(
      materialId: materialId is String ? materialId : '',
      pageNo: pageNo is int ? pageNo : 0,
      quote: quote is String ? quote.trim() : '',
      verified: value['verified'] == true,
      isDocx: value['is_docx'] == true,
      materialTitle:
          (value['material_title'] as String?) ??
          (materialId is String ? materialTitles[materialId] : null),
    );
  }

  final String materialId;
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
