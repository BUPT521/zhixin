import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/memory_scope_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

/// 记录按编号读了几次；调用方已经读过记录时，这里不该再增加。
class _CountingConversations extends ConversationRepository {
  _CountingConversations(super.db);

  int reads = 0;

  @override
  Future<ConversationRecord?> byId(
    int conversationId, {
    WriteTransaction? transaction,
  }) {
    reads++;
    return super.byId(conversationId, transaction: transaction);
  }
}

void main() {
  test('传入已读记录时不按编号再读一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final conversations = _CountingConversations(rig.db.rawDb);
    final service = MemoryScopeService(
      conversations: conversations,
      attempts: AttemptRepository(rig.db.rawDb),
    );

    final resolved = await service.resolve(
      42,
      record: const ConversationRecord(id: 42, goalId: 7, materialId: 3),
    );

    expect(resolved.goalId, 7);
    expect(resolved.scope, memoryGoalScope(7));
    expect(conversations.reads, 0);
  });

  test('没有传入记录时仍按编号读取', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final conversations = _CountingConversations(rig.db.rawDb);
    final id = await conversations.create(title: '讨论');
    final service = MemoryScopeService(
      conversations: conversations,
      attempts: AttemptRepository(rig.db.rawDb),
    );

    conversations.reads = 0;
    await service.resolve(id);

    expect(conversations.reads, 1);
  });
}
