import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/discussion_service.dart';
import 'package:zhixin/application/memory_scope_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/result.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

class _NoAi implements BuddyAi {
  @override
  Future<Result<LlmConfig?>> config() async => const Success(null);

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async => const BuddyReply(text: '好');
}

void main() {
  test('确认推断记忆时写进库并形成提交，卡片可以撤销回待确认', () async {
    final rig = await openTestRigWithUndoRules(
      clock: () => DateTime(2026, 11, 10, 10),
    );
    addTearDown(rig.close);

    final conversations = ConversationRepository(rig.db);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final memories = MemoryRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = DiscussionService(
      conversations: conversations,
      ai: _NoAi(),
      context: ContextService(
        tasks: tasks,
        attempts: AttemptRepository(rig.db),
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: MaterialRepository(rig.db),
        runtime: testRuntime(policy: () => policy),
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: AttemptRepository(rig.db),
      ),
      memories: memories,
      revisions: rig.revisions,
      tasks: tasks,
      materials: MaterialRepository(rig.db),
      runtime: testRuntime(policy: () => policy),
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      cleanupAttachmentPaths: (_) async {},
      assets: AssetStore(),
    );
    final conversationId = await conversations.create(title: '记忆');
    final message = await conversations.append(
      conversationId,
      role: MessageRole.assistant,
      content: '回答',
      payload: const ChatMessagePayload(
        memoryItems: [
          MemoryDraft(
            id: 'memory-1',
            kind: MemoryKind.semantic,
            content: '讲解概率时先用具体例子。',
            source: MemorySource.inferred,
          ),
        ],
      ),
    );
    final accepted = await service.acceptMemoryItem(
      conversationId: conversationId,
      messageId: message.id,
      itemId: 'memory-1',
    );
    expect(accepted.applied, isTrue);

    // 记忆按模型给出的语义标签写进库；用户手写的类别不参与推断。
    final saved = (await memories.list()).single;
    expect(saved.kind, MemoryKind.semantic);
    expect(saved.content, '讲解概率时先用具体例子。');
    expect(saved.sourceKind, MemorySourceKind.message);
    expect(saved.sourceId, message.id);
    final stored = await conversations.messageById(message.id);
    final item = stored!.payload!.memoryItems.single;
    expect(item.status, MemoryCardStatus.accepted);
    expect(item.commitId, isNotNull);

    // 撤销这次确认：记忆回到不存在，卡片回到待确认。
    final undone = await rig.revisions.undoCommit(item.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await memories.list(), isEmpty);
    final reverted = await conversations.messageById(message.id);
    expect(
      reverted!.payload!.memoryItems.single.status,
      MemoryCardStatus.pending,
    );
    expect(await conversations.byId(conversationId), isNotNull);
  });
}
