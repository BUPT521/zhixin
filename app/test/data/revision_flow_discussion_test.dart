import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/discussion_service.dart';
import 'package:zhixin/application/memory_scope_service.dart';
import 'package:zhixin/data/attachment_store.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';

class _FixedAi implements BuddyAi {
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
  }) async {
    onText?.call('带着图片的回答。');
    return const BuddyReply(text: '带着图片的回答。');
  }
}

class _Rig {
  _Rig(this.dir);

  final Directory dir;
  late Database raw;
  late GuardedDatabase db;
  late RevisionEngine engine;
  late RevisionService revisions;
  late AttachmentCache cache;
  late DiscussionService discussion;
  late ConversationRepository conversations;

  String get dbPath => '${dir.path}/zhixin.db';
  String get filesDir => '${dir.path}/files';

  Future<void> open() async {
    await Directory(filesDir).create(recursive: true);
    raw = await openZhixinDatabase(factory: databaseFactoryFfi, path: dbPath);
    engine = RevisionEngine();
    cache = AttachmentCache(filesDir: () => filesDir);
    db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    revisions = RevisionService(
      db: db,
      raw: () => raw,
      engine: engine,
      clock: () => DateTime(2026, 11, 10, 10),
      cache: cache,
    );
    final conversations = ConversationRepository(db);
    this.conversations = conversations;
    final tasks = TaskRepository(db);
    final schedule = ScheduleRepository(db);
    final memories = MemoryRepository(db);
    final attempts = AttemptRepository(db);
    final materials = MaterialRepository(db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    discussion = DiscussionService(
      conversations: conversations,
      ai: _FixedAi(),
      context: ContextService(
        tasks: tasks,
        attempts: attempts,
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: materials,
        runtime: testRuntime(policy: () => policy),
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: attempts,
      ),
      memories: memories,
      revisions: revisions,
      tasks: tasks,
      materials: materials,
      runtime: testRuntime(policy: () => policy, filesDir: () => filesDir),
      transactions: WriteTransactions(db),
      cleanupAttachmentPaths: (paths) =>
          AttachmentStore(filesDir: filesDir).cleanupCandidates(db, paths),
      assets: engine.assets,
      cache: cache,
    );
  }

  Future<void> close() => raw.close();
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('带图讨论提交、重复图片去重、删除、重启与整版恢复', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_flow_discussion');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final rig = _Rig(dir);
    await rig.open();

    final image = File('${dir.path}/question.png');
    final bytes = Uint8List.fromList(
      List<int>.generate(1024, (index) => (index * 31) % 251),
    );
    await image.writeAsBytes(bytes);
    final copy = await image.copy('${dir.path}/question-copy.png');
    final hash = AssetStore.hashBytes(bytes);

    final result = await rig.discussion.reply(
      text: '这道题怎么想',
      imagePaths: [image.path, copy.path],
    );
    final conversationId = result.userMessage.conversationId;
    expect(result.userMessage.imagePaths, [hash]);
    expect(
      await rig.raw.query('asset_object', where: 'hash = ?', whereArgs: [hash]),
      hasLength(1),
    );
    expect(await rig.engine.assets.verify(rig.raw, hash), isTrue);

    // 再发一张完全相同的图片：附件对象复用，不重复分块。
    await rig.discussion.reply(
      conversationId: conversationId,
      text: '再贴一次',
      imagePaths: [image.path],
    );
    expect(await rig.raw.query('asset_object'), hasLength(1));
    expect(await rig.raw.query('asset_chunk'), isNotEmpty);

    final submittedHead = await rig.engine.headId(rig.raw);
    final submitted = await rig.engine.readProjection(rig.raw);
    expect(submitted['conversation'], isNotEmpty);
    expect(submitted['message'], isNotEmpty);

    // 删除讨论后重启：业务行和版本历史都还在，当前数据没有这条讨论。
    await rig.discussion.clear(conversationId);
    expect(await rig.raw.query('conversation'), isEmpty);
    await rig.close();
    await rig.open();
    expect(await rig.raw.query('conversation'), isEmpty);
    expect(await rig.engine.projectionAt(rig.raw, submittedHead), submitted);

    // 整版恢复到提交时的版本，逐字段比较全部业务表。
    final currentHead = await rig.engine.headId(rig.raw);
    final preview = await rig.revisions.previewRestore(submittedHead);
    expect(preview.head, currentHead);
    expect(preview.diff.insertCount, greaterThan(0));
    await rig.revisions.restore(submittedHead, expectedHead: currentHead);
    final restored = await rig.engine.readProjection(rig.raw);
    expect(restored, submitted);
    expect(
      await rig.raw.query(
        'conversation',
        where: 'id = ?',
        whereArgs: [conversationId],
      ),
      hasLength(1),
    );
    final messages = await rig.raw.query(
      'message',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'id',
    );
    expect(messages, isNotEmpty);
    final refs = <String>[
      for (final row in messages)
        if (row['image_paths_json'] case final String raw)
          ...(jsonDecode(raw) as List).whereType<String>(),
    ];
    expect(refs, contains(hash));
    expect(await rig.engine.assets.verify(rig.raw, hash), isTrue);
    expect(File(rig.cache.pathFor(hash)).existsSync(), isTrue);
    await rig.close();
  });

  test('写入中断时业务数据、附件与 HEAD 一起回滚', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_flow_rollback');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final rig = _Rig(dir);
    await rig.open();
    final head = await rig.engine.headId(rig.raw);
    final bytes = Uint8List.fromList(List<int>.generate(300, (i) => i));
    final hash = AssetStore.hashBytes(bytes);
    await expectLater(
      rig.db.transaction((txn) async {
        final conversation = await txn.insert('conversation', {
          'title': '中断',
          'entry_kind': 'photo',
          'status': 'open',
          'created_at': '2026-11-10T10:00:00',
          'updated_at': '2026-11-10T10:00:00',
        });
        await rig.engine.assets.putBytes(txn, hash, bytes);
        await txn.insert('message', {
          'conversation_id': conversation,
          'role': 'user',
          'content': '',
          'image_paths_json': '["$hash"]',
          'created_at': '2026-11-10T10:00:00',
        });
        throw StateError('模拟提交前中断');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await rig.engine.headId(rig.raw), head);
    expect(await rig.raw.query('conversation'), isEmpty);
    expect(await rig.raw.query('message'), isEmpty);
    expect(await rig.raw.query('asset_object'), isEmpty);
    expect(await rig.raw.query('asset_chunk'), isEmpty);
    await rig.close();
  });
}
