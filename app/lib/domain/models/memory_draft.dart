import '../rules/coded_enum.dart';
import '../rules/content_identity.dart' as identity;
import '../rules/time_format.dart';
import 'memory.dart';

/// 一条记忆进入库、消息或帮助之前的草案形态；模型推断与用户明说都走这里。
///
/// 讨论里存进回答消息的 `memory_items`、作答里随帮助存进 `help_json` 的
/// `memories`，以及模型工具给出的记忆，原先分别是三个类、两套序列化；现在
/// 卡片编号、处理状态与提交编号也放在这里，存储与读取只认这一份。
class MemoryDraft {
  const MemoryDraft({
    required this.kind,
    required this.content,
    this.validUntil,
    this.source = MemorySource.inferred,
    this.id = '',
    this.status = MemoryCardStatus.pending,
    this.commitId,
  });

  final MemoryKind kind;
  final String content;
  final DateTime? validUntil;

  /// 这句话是用户明确说的，还是模型根据记录推断的。
  final MemorySource source;

  /// 卡片在所属消息或帮助里的编号；只在存储后使用，模型给出的草案为空。
  final String id;

  /// 卡片当前的处理状态；写入后带回执，撤销后回到待确认。
  final MemoryCardStatus status;

  /// 写入记忆的那次提交；撤销之后这条卡片回到待确认并清掉编号。
  final int? commitId;

  /// 内容是否超过写入上限；超长的记忆不截半句，直接不写。
  bool get tooLong => content.trim().length > memoryContentLimit;

  String get contentId => identity.contentId('memory', [
    kind.value,
    content.trim(),
    validUntil?.toUtc().toIso8601String(),
    source.value,
  ]);

  MemoryDraft copyWith({
    MemoryCardStatus? status,
    int? commitId,
    bool clearCommitId = false,
  }) => MemoryDraft(
    kind: kind,
    content: content,
    validUntil: validUntil,
    source: source,
    id: id,
    status: status ?? this.status,
    commitId: clearCommitId ? null : (commitId ?? this.commitId),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.value,
    'content': content,
    if (validUntil != null) 'valid_until': formatDateTime(validUntil!),
    'source': source.value,
    'status': status.value,
    if (commitId != null) 'commit_id': commitId,
  };

  /// 读回一条草案；内容为空、类型或时刻坏掉的条目整条丢弃。
  static MemoryDraft? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = value['kind'];
    final content = value['content'];
    if (kind is! String || content is! String || content.trim().isEmpty) {
      return null;
    }
    final id = value['id'];
    final status = value['status'];
    final validUntil = value['valid_until'];
    final source = value['source'];
    final commitId = value['commit_id'];
    final DateTime? parsedUntil;
    try {
      parsedUntil = validUntil is String ? optionalDateTime(validUntil) : null;
    } on FormatException {
      // 模型给出的时刻坏了只当作没有期限，不让整条回答失败。
      return null;
    }
    return MemoryDraft(
      id: id is String ? id : '',
      kind: MemoryKind.fromValue(kind),
      content: content.trim(),
      validUntil: parsedUntil,
      source: source == MemorySource.user.value
          ? MemorySource.user
          : MemorySource.inferred,
      status: MemoryCardStatus.fromValue(status is String ? status : null),
      commitId: commitId is int ? commitId : null,
    );
  }

  static List<MemoryDraft> decodeList(Object? value) => [
    if (value is List)
      for (final item in value) ?fromJson(item),
  ];
}

/// 记忆是用户明确说的，还是模型根据记录推断的；两者进入卡片的方式不同。
enum MemorySource {
  user('user'),
  inferred('inferred');

  const MemorySource(this.value);

  final String value;
}

/// 一条记忆卡片的处理状态；只在草案所属的消息或帮助里记录。
enum MemoryCardStatus implements CodedEnum {
  pending('pending', '待确认'),
  accepted('accepted', '已记下'),
  dismissed('dismissed', '不记'),
  unknown('', '状态未知');

  const MemoryCardStatus(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static MemoryCardStatus fromValue(String? value) =>
      codedValueOr(MemoryCardStatus.values, value, unknown: unknown);
}

/// 单条记忆允许写入的长度；讨论、作答与模型工具描述共用这一个上限。
const int memoryContentLimit = 200;
