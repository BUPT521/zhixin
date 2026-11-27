import 'dart:convert';

import '../rules/notices.dart';
import 'material.dart';
import 'memory_draft.dart';

/// 一条消息的结构化补充（01 `message.structured_json`）。
///
/// 写侧由讨论服务组装一次；读侧的引用、下一步建议、记忆卡片状态、操作回执、
/// 撤销与回执清理都从这里取字段。原先这些位置各写一份 JSON 解析，键名与缺失值
/// 的处理稍有差别，现在只认这一个模型；JSON 键名保持原样，旧消息仍能读回。
class ChatMessagePayload {
  const ChatMessagePayload({
    this.fromModel,
    this.stopped = false,
    this.interrupted = false,
    this.modelFailed = false,
    this.failureName,
    this.quotaReason,
    this.notices = const [],
    this.memoryItems = const [],
    this.nextSteps = const [],
    this.citations = const [],
    this.acceptedTitles = const <String>{},
    this.acceptedStepIds = const <String>{},
    this.dismissedTitles = const <String>{},
    this.dismissedStepIds = const <String>{},
    this.operations = const [],
    this.usedPages = const [],
  });

  /// 正文来源：`true` 来自模型、`false` 来自本地规则、空表示没有记录。
  final bool? fromModel;

  /// 用户在生成过程中点了停止。
  final bool stopped;

  /// 正文已经显示之后生成中断。
  final bool interrupted;

  /// 模型不可用，已退回本地规则。
  final bool modelFailed;

  /// 模型失败的类型名（`LlmFailure.name`）；由应用层映射成枚举。
  final String? failureName;

  /// 额度用完的具体原因名（`QuotaExhaustedReason.name`）；重新打开讨论时按它写
  /// 下一步说法，旧消息没有这一项。
  final String? quotaReason;

  /// 这次回答需要界面区分的情况。
  final List<Notice> notices;

  /// 这次回答给出的记忆卡片，带卡片编号、处理状态与提交编号。
  final List<MemoryDraft> memoryItems;

  /// 这次回答给出的下一步建议。
  final List<ChatNextStep> nextSteps;

  /// 这次回答的引用；是否核对过由写入时决定。
  final List<Citation> citations;

  /// 已经接受的建议标题与编号；旧消息只按标题记，新消息两者都记。
  final Set<String> acceptedTitles;
  final Set<String> acceptedStepIds;

  /// 暂不安排的建议标题与编号。
  final Set<String> dismissedTitles;
  final Set<String> dismissedStepIds;

  /// 这次回答带来的写入回执，撤销时按提交编号清掉。
  final List<ChatOperationReceipt> operations;

  /// 这次回答读到的材料页；重试同一条问题时据此接续，不再重新补搜。
  final List<ChatUsedPage> usedPages;

  bool get isEmpty =>
      fromModel == null &&
      !stopped &&
      !interrupted &&
      !modelFailed &&
      failureName == null &&
      quotaReason == null &&
      notices.isEmpty &&
      memoryItems.isEmpty &&
      nextSteps.isEmpty &&
      citations.isEmpty &&
      acceptedTitles.isEmpty &&
      acceptedStepIds.isEmpty &&
      dismissedTitles.isEmpty &&
      dismissedStepIds.isEmpty &&
      operations.isEmpty &&
      usedPages.isEmpty;

  /// 这条建议是否已经处理：有编号时按编号判断，旧消息只有标题时按标题判断。
  bool isStepHandled(String stepId, String title) =>
      acceptedStepIds.isNotEmpty || dismissedStepIds.isNotEmpty
      ? acceptedStepIds.contains(stepId) || dismissedStepIds.contains(stepId)
      : acceptedTitles.contains(title) || dismissedTitles.contains(title);

  MemoryDraft? memoryItem(String itemId) {
    for (final item in memoryItems) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  /// 记下一条建议已经接受，并写入这次提交的操作回执。
  ChatMessagePayload acceptedStep(
    String title, {
    String? stepId,
    int? commitId,
  }) {
    final receipts = commitId == null
        ? operations
        : [
            for (final receipt in operations)
              if (receipt.commitId != commitId) receipt,
            ChatOperationReceipt(commitId: commitId, text: '已添加事项：$title'),
          ];
    return ChatMessagePayload(
      fromModel: fromModel,
      stopped: stopped,
      interrupted: interrupted,
      modelFailed: modelFailed,
      failureName: failureName,
      quotaReason: quotaReason,
      notices: notices,
      memoryItems: memoryItems,
      nextSteps: nextSteps,
      citations: citations,
      acceptedTitles: {...acceptedTitles, title},
      acceptedStepIds: stepId == null
          ? acceptedStepIds
          : {...acceptedStepIds, stepId},
      dismissedTitles: dismissedTitles,
      dismissedStepIds: dismissedStepIds,
      operations: receipts,
      usedPages: usedPages,
    );
  }

  /// 记下一条建议暂不安排。
  ChatMessagePayload dismissedStep(String title, {String? stepId}) =>
      ChatMessagePayload(
        fromModel: fromModel,
        stopped: stopped,
        interrupted: interrupted,
        modelFailed: modelFailed,
        failureName: failureName,
        quotaReason: quotaReason,
        notices: notices,
        memoryItems: memoryItems,
        nextSteps: nextSteps,
        citations: citations,
        acceptedTitles: acceptedTitles,
        acceptedStepIds: acceptedStepIds,
        dismissedTitles: {...dismissedTitles, title},
        dismissedStepIds: stepId == null
            ? dismissedStepIds
            : {...dismissedStepIds, stepId},
        operations: operations,
        usedPages: usedPages,
      );

  /// 更新一条记忆卡片的处理状态；没有这张卡片时返回空。
  ChatMessagePayload? memoryItemStatus(
    String itemId,
    MemoryCardStatus status, {
    int? commitId,
  }) {
    final items = <MemoryDraft>[];
    var found = false;
    for (final item in memoryItems) {
      if (item.id != itemId) {
        items.add(item);
        continue;
      }
      found = true;
      items.add(
        item.copyWith(
          status: status,
          commitId: commitId,
          clearCommitId: commitId == null,
        ),
      );
    }
    if (!found) return null;
    return _copyWith(memoryItems: items);
  }

  /// 撤销一次提交之后的清理：去掉指向它的回执，把撤销恢复的标题与编号从已接受
  /// 里移出，把对应的记忆卡片放回待确认。
  ///
  /// 没有需要改动的内容时返回空，调用方据此不更新消息。
  ChatMessagePayload? withoutReceipts(
    int commitId, {
    Set<String> unacceptedTitles = const <String>{},
    Set<String> unacceptedStepIds = const <String>{},
  }) {
    var changed = false;
    final receipts = <ChatOperationReceipt>[];
    for (final receipt in operations) {
      if (receipt.commitId == commitId) {
        changed = true;
      } else {
        receipts.add(receipt);
      }
    }
    final items = <MemoryDraft>[];
    for (final item in memoryItems) {
      if (item.commitId != commitId) {
        items.add(item);
        continue;
      }
      changed = true;
      items.add(
        item.copyWith(status: MemoryCardStatus.pending, clearCommitId: true),
      );
    }
    final titles = unacceptedTitles.isEmpty
        ? acceptedTitles
        : acceptedTitles.difference(unacceptedTitles);
    if (titles.length != acceptedTitles.length) changed = true;
    final ids = unacceptedStepIds.isEmpty
        ? acceptedStepIds
        : acceptedStepIds.difference(unacceptedStepIds);
    if (ids.length != acceptedStepIds.length) changed = true;
    if (!changed) return null;
    return _copyWith(
      memoryItems: items,
      operations: receipts,
      acceptedTitles: titles,
      acceptedStepIds: ids,
    );
  }

  /// 清掉指向已删除提交的回执；记忆卡片只去掉编号，状态保持不变。
  ///
  /// 没有需要改动的内容时返回空。
  ChatMessagePayload? withoutDeadReceipts(Set<int> liveCommits) {
    var changed = false;
    final receipts = <ChatOperationReceipt>[];
    for (final receipt in operations) {
      if (liveCommits.contains(receipt.commitId)) {
        receipts.add(receipt);
      } else {
        changed = true;
      }
    }
    final items = <MemoryDraft>[];
    for (final item in memoryItems) {
      final commitId = item.commitId;
      if (commitId == null || liveCommits.contains(commitId)) {
        items.add(item);
        continue;
      }
      changed = true;
      items.add(item.copyWith(clearCommitId: true));
    }
    if (!changed) return null;
    return _copyWith(memoryItems: items, operations: receipts);
  }

  ChatMessagePayload _copyWith({
    List<MemoryDraft>? memoryItems,
    List<ChatOperationReceipt>? operations,
    Set<String>? acceptedTitles,
    Set<String>? acceptedStepIds,
  }) => ChatMessagePayload(
    fromModel: fromModel,
    stopped: stopped,
    interrupted: interrupted,
    modelFailed: modelFailed,
    failureName: failureName,
    quotaReason: quotaReason,
    notices: notices,
    memoryItems: memoryItems ?? this.memoryItems,
    nextSteps: nextSteps,
    citations: citations,
    acceptedTitles: acceptedTitles ?? this.acceptedTitles,
    acceptedStepIds: acceptedStepIds ?? this.acceptedStepIds,
    dismissedTitles: dismissedTitles,
    dismissedStepIds: dismissedStepIds,
    operations: operations ?? this.operations,
    usedPages: usedPages,
  );

  Map<String, Object?> toJson() => {
    if (fromModel != null) 'model': fromModel,
    if (stopped) 'stopped': true,
    if (interrupted) 'interrupted': true,
    if (modelFailed) 'model_failed': true,
    if (modelFailed && failureName != null) 'model_failure': failureName,
    if (modelFailed && quotaReason != null) 'model_quota_reason': quotaReason,
    if (notices.isNotEmpty)
      'notices': [for (final notice in notices) notice.value],
    if (memoryItems.isNotEmpty)
      'memory_items': [for (final item in memoryItems) item.toJson()],
    if (nextSteps.isNotEmpty)
      'next_steps': [for (final step in nextSteps) step.toJson()],
    if (citations.isNotEmpty)
      'citations': [for (final citation in citations) citation.toJson()],
    if (acceptedTitles.isNotEmpty) 'accepted': acceptedTitles.toList(),
    if (acceptedStepIds.isNotEmpty) 'accepted_ids': acceptedStepIds.toList(),
    if (dismissedTitles.isNotEmpty) 'dismissed': dismissedTitles.toList(),
    if (dismissedStepIds.isNotEmpty) 'dismissed_ids': dismissedStepIds.toList(),
    if (operations.isNotEmpty)
      'operations': [for (final receipt in operations) receipt.toJson()],
    if (usedPages.isNotEmpty)
      'used_pages': [for (final page in usedPages) page.toJson()],
  };

  String? encode() => isEmpty ? null : jsonEncode(toJson());

  /// 读回一条消息的结构化补充；没有内容或整段坏掉时返回空。
  static ChatMessagePayload? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return _fromMap({
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: entry.value,
      });
    } on FormatException {
      return null;
    }
  }

  static ChatMessagePayload _fromMap(Map<String, Object?> map) {
    final rawNotices = map['notices'];
    final rawCitations = map['citations'];
    final rawSteps = map['next_steps'];
    return ChatMessagePayload(
      fromModel: map['model'] is bool ? map['model'] as bool : null,
      stopped: map['stopped'] == true,
      interrupted: map['interrupted'] == true,
      modelFailed: map['model_failed'] == true,
      failureName: map['model_failure'] is String
          ? map['model_failure'] as String
          : null,
      quotaReason: switch (map['model_quota_reason']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      notices: [
        if (rawNotices is List)
          for (final value in rawNotices) ?noticeFromValue(value?.toString()),
      ],
      memoryItems: MemoryDraft.decodeList(map['memory_items']),
      nextSteps: [
        if (rawSteps is List)
          for (final (index, value) in rawSteps.indexed)
            ?ChatNextStep.fromJson(value, index: index),
      ],
      citations: [
        if (rawCitations is List)
          for (final value in rawCitations) Citation.fromJson(value),
      ],
      acceptedTitles: _stringSet(map['accepted']),
      acceptedStepIds: _stringSet(map['accepted_ids']),
      dismissedTitles: _stringSet(map['dismissed']),
      dismissedStepIds: _stringSet(map['dismissed_ids']),
      operations: [
        if (map['operations'] case final List raw)
          for (final value in raw)
            if (value is Map &&
                value['commit_id'] is int &&
                value['text'] is String)
              ChatOperationReceipt(
                commitId: value['commit_id'] as int,
                text: value['text'] as String,
              ),
      ],
      usedPages: [
        if (map['used_pages'] case final List raw)
          for (final value in raw) ?ChatUsedPage.fromJson(value),
      ],
    );
  }

  static Set<String> _stringSet(Object? raw) => {
    if (raw is List)
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
  };
}

/// 一条下一步建议：编号在消息里唯一，标题与说明留在草案里。
class ChatNextStep {
  const ChatNextStep({
    required this.id,
    required this.title,
    this.action,
    this.endCondition,
    this.minutes,
  });

  final String id;
  final String title;
  final String? action;
  final String? endCondition;
  final int? minutes;

  static ChatNextStep? fromJson(Object? value, {required int index}) {
    if (value is! Map) return null;
    final title = value['title'];
    if (title is! String || title.trim().isEmpty) return null;
    final id = value['id'];
    final action = value['action'];
    final endCondition = value['end_condition'];
    final minutes = value['minutes'];
    return ChatNextStep(
      id: id is String && id.isNotEmpty ? id : 's${index + 1}',
      title: title.trim(),
      action: action is String ? action.trim() : null,
      endCondition: endCondition is String ? endCondition.trim() : null,
      minutes: minutes is int ? minutes : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'action': action,
    'end_condition': endCondition,
    'minutes': minutes,
  };
}

/// 一次写入留下的回执：撤销入口按提交编号找回它。
class ChatOperationReceipt {
  const ChatOperationReceipt({required this.commitId, required this.text});

  final int commitId;
  final String text;

  Map<String, Object?> toJson() => {'commit_id': commitId, 'text': text};
}

/// 这一次回答读到的一页材料。
///
/// 只记材料与页码，不记原文：重试时按当前位置重新读取当前保存的内容，材料被
/// 删除或页码不存在时这一页自然跳过，因此接续不会把更正前的旧原文带回回答。
class ChatUsedPage {
  const ChatUsedPage({required this.materialId, required this.pageNo});

  final String materialId;
  final int pageNo;

  (String, int) get pageKey => (materialId, pageNo);

  Map<String, Object?> toJson() => {
    'material_id': materialId,
    'page_no': pageNo,
  };

  static ChatUsedPage? fromJson(Object? value) {
    if (value is! Map) return null;
    final materialId = value['material_id'];
    final pageNo = value['page_no'];
    if (materialId is! String || materialId.isEmpty || pageNo is! int) {
      return null;
    }
    return ChatUsedPage(materialId: materialId, pageNo: pageNo);
  }
}
