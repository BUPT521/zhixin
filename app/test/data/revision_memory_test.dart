import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

class _NoAi implements BuddyAi {
  @override
  Future<LlmConfig?> config() async => null;

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
  setUpAll(sqfliteFfiInit);

  test('确认推断记忆后消息状态与回执一起提交', () async {
    final rig = await openTestRig(clock: () => DateTime(2026, 11, 10, 10));
    addTearDown(rig.close);

    final conversations = ConversationRepository(rig.db.rawDb);
    final tasks = TaskRepository(rig.db.rawDb);
    final schedule = ScheduleRepository(rig.db.rawDb);
    final memories = MemoryRepository(rig.db.rawDb);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = DiscussionService(
      conversations: conversations,
      ai: _NoAi(),
      context: ContextService(
        tasks: tasks,
        attempts: AttemptRepository(rig.db.rawDb),
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: MaterialRepository(rig.db.rawDb),
        runtime: testRuntime(policy: () => policy),
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: AttemptRepository(rig.db.rawDb),
      ),
      memories: memories,
      revisions: rig.revisions,
      tasks: tasks,
      materials: MaterialRepository(rig.db.rawDb),
      runtime: testRuntime(policy: () => policy),
      transactions: WriteTransactions(rig.db),
      cleanupAttachmentPaths: (_) async {},
      assets: AssetStore(),
    );
    final conversationId = await conversations.create(title: '记忆');
    final message = await conversations.append(
      conversationId,
      role: 'assistant',
      content: '回答',
      structured: {
        'memory_items': [
          {
            'id': 'memory-1',
            'kind': 'preference',
            'content': '讲解概率时先用具体例子。',
            'source': 'inferred',
            'status': 'pending',
          },
        ],
      },
    );
    final result = await service.acceptMemoryItem(
      conversationId: conversationId,
      messageId: message.id,
      itemId: 'memory-1',
    );
    expect(result.applied, isTrue);
    final stored = await conversations.messageById(message.id);
    expect(stored!.structured?['memory_items'], isA<List>());
    final items = stored.structured!['memory_items'] as List;
    expect((items.single as Map)['status'], 'accepted');
    expect(await memories.list(), hasLength(1));
    final commitId = (items.single as Map)['commit_id'] as int;
    expect(await rig.revisions.activeCommits([commitId]), {commitId});
    final undone = await rig.revisions.undoCommit(commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await memories.list(), isEmpty);
    final restored = await conversations.messageById(message.id);
    final restoredItems = restored!.structured!['memory_items'] as List;
    expect((restoredItems.single as Map)['status'], 'pending');
  });
}
