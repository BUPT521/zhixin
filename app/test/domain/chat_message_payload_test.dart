import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/memory_draft.dart';
import 'package:zhixin/domain/rules/notices.dart';

/// 一条带齐各类字段的回答：来源、提示、记忆卡片、建议、引用与回执。
ChatMessagePayload sample() => ChatMessagePayload(
  fromModel: true,
  notices: const [Notice.answerTruncated],
  memoryItems: const [
    MemoryDraft(
      id: 'm0',
      kind: MemoryKind.semantic,
      content: '讲解概率时先用具体例子。',
      validUntil: null,
      source: MemorySource.user,
      status: MemoryCardStatus.accepted,
      commitId: 12,
    ),
  ],
  nextSteps: const [
    ChatNextStep(
      id: 's1',
      title: '用抽球问题练习条件概率',
      action: '分别写出已知条件与要求的事件。',
      endCondition: '能独立写对两题。',
      minutes: 10,
    ),
  ],
  citations: const [
    Citation(
      materialId: 'mat-1',
      pageNo: 7,
      quote: '条件概率是已知一个事件发生时，另一个事件发生的概率。',
      verified: true,
      materialTitle: '概率论讲义',
    ),
  ],
  acceptedTitles: const {'用抽球问题练习条件概率'},
  acceptedStepIds: const {'s1'},
  operations: const [
    ChatOperationReceipt(commitId: 12, text: '已添加安排：用抽球问题练习条件概率'),
  ],
  usedPages: const [
    ChatUsedPage(materialId: 'mat-1', pageNo: 7),
    ChatUsedPage(materialId: 'mat-2', pageNo: 3),
  ],
);

void main() {
  test('结构化补充编码之后能原样读回', () {
    final payload = sample();
    final restored = ChatMessagePayload.decode(payload.encode())!;
    expect(restored.fromModel, isTrue);
    expect(restored.notices, [Notice.answerTruncated]);
    final item = restored.memoryItems.single;
    expect(item.id, 'm0');
    expect(item.kind, MemoryKind.semantic);
    expect(item.source, MemorySource.user);
    expect(item.status, MemoryCardStatus.accepted);
    expect(item.commitId, 12);
    final step = restored.nextSteps.single;
    expect(step.id, 's1');
    expect(step.endCondition, '能独立写对两题。');
    expect(step.minutes, 10);
    expect(restored.citations.single.materialTitle, '概率论讲义');
    expect(restored.isStepHandled('s1', '用抽球问题练习条件概率'), isTrue);
    expect(restored.operations.single.text, '已添加安排：用抽球问题练习条件概率');
    expect(restored.usedPages.map((page) => page.pageKey), [
      ('mat-1', 7),
      ('mat-2', 3),
    ]);
    // 再编码一次与第一次相同，回执清理不会改变无关字段。
    expect(restored.encode(), payload.encode());
  });

  test('额度用完的原因随回答保存，复制路径与旧消息都能读回', () {
    final payload = ChatMessagePayload.decode(
      jsonEncode({
        'model': false,
        'model_failed': true,
        'model_failure': 'quotaExhausted',
        'model_quota_reason': 'points',
      }),
    )!;
    expect(payload.quotaReason, 'points');
    expect(ChatMessagePayload.decode(payload.encode())?.quotaReason, 'points');

    // 建议状态与回执清理都复制整条补充，额度原因不能在这一步丢掉。
    expect(payload.acceptedStep('复习错题', stepId: 's1').quotaReason, 'points');
    expect(payload.dismissedStep('复习错题').quotaReason, 'points');
    expect(payload.withoutReceipts(99), isNull);

    // 旧消息没有这一项；空值也不写进 JSON。
    final noReason = ChatMessagePayload.decode(
      jsonEncode({'model_failed': true, 'model_failure': 'quotaExhausted'}),
    )!;
    expect(noReason.quotaReason, isNull);
    expect(noReason.encode(), isNot(contains('model_quota_reason')));
    expect(const ChatMessagePayload(quotaReason: 'points').isEmpty, isFalse);
  });

  test('读回接续页时丢掉没有材料或页码的条目', () {
    final payload = ChatMessagePayload.decode(
      jsonEncode({
        'used_pages': [
          {'material_id': 'mat-1', 'page_no': 2},
          {'material_id': '', 'page_no': 3},
          {'page_no': 4},
          {'material_id': 'mat-2', 'page_no': 'x'},
        ],
      }),
    )!;
    expect(payload.usedPages.single.materialId, 'mat-1');
    expect(payload.usedPages.single.pageNo, 2);
  });

  test('旧消息只有标题与编号时按原有口径判断建议是否已处理', () {
    final payload = ChatMessagePayload.decode(
      jsonEncode({
        'model': false,
        'next_steps': [
          {'id': 's2', 'title': '复习错题', 'minutes': 5},
        ],
        'accepted': ['复习错题'],
      }),
    )!;
    expect(payload.fromModel, isFalse);
    expect(payload.nextSteps.single.id, 's2');
    expect(payload.isStepHandled('s2', '复习错题'), isTrue);

    final byId = ChatMessagePayload.decode(
      jsonEncode({
        'next_steps': [
          {'id': 's2', 'title': '复习错题'},
        ],
        'dismissed_ids': ['s2'],
      }),
    )!;
    expect(byId.isStepHandled('s2', '复习错题'), isTrue);
  });

  test('记忆卡片更新只动命中的一条，没有命中时不改消息', () {
    final payload = sample();
    final dismissed = payload.memoryItemStatus(
      'm0',
      MemoryCardStatus.dismissed,
    )!;
    expect(dismissed.memoryItems.single.status, MemoryCardStatus.dismissed);
    expect(dismissed.memoryItems.single.commitId, isNull);
    expect(
      payload.memoryItemStatus('missing', MemoryCardStatus.dismissed),
      isNull,
    );
  });

  test('撤销清理去掉本次提交的回执并放回卡片，没有可清理项时返回空', () {
    final payload = sample();
    final cleaned = payload.withoutReceipts(
      12,
      unacceptedTitles: const {'用抽球问题练习条件概率'},
      unacceptedStepIds: const {'s1'},
    )!;
    expect(cleaned.operations, isEmpty);
    expect(cleaned.acceptedTitles, isEmpty);
    expect(cleaned.acceptedStepIds, isEmpty);
    expect(cleaned.memoryItems.single.status, MemoryCardStatus.pending);
    expect(cleaned.memoryItems.single.commitId, isNull);
    expect(payload.withoutReceipts(99), isNull);
  });

  test('回执清理只保留仍能撤销的提交，记忆卡片状态不变', () {
    final payload = sample();
    expect(payload.withoutDeadReceipts({12}), isNull);
    final cleaned = payload.withoutDeadReceipts(const {})!;
    expect(cleaned.operations, isEmpty);
    expect(cleaned.memoryItems.single.status, MemoryCardStatus.accepted);
    expect(cleaned.memoryItems.single.commitId, isNull);
  });

  test('记忆草案序列化一套，超过上限不写', () {
    const draft = MemoryDraft(
      id: 'm3',
      kind: MemoryKind.semantic,
      content: '本周晚上只有半小时。',
      source: MemorySource.inferred,
    );
    final restored = MemoryDraft.fromJson(draft.toJson())!;
    expect(restored.id, 'm3');
    expect(restored.content, '本周晚上只有半小时。');
    expect(restored.toJson(), draft.toJson());
    expect(draft.tooLong, isFalse);
    expect(
      MemoryDraft(
        kind: MemoryKind.semantic,
        content: '长' * (memoryContentLimit + 1),
      ).tooLong,
      isTrue,
    );
  });
}
