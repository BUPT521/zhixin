import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/result.dart';
import 'package:zhixin/domain/rules/notices.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/learning_page.dart';

import '../support/fake_server.dart';
import '../support/sync_rig.dart';
import 'workspace_support.dart';

class _RetryHelpAi implements BuddyAi {
  final modes = <BuddyMode>[];

  @override
  Future<Result<LlmConfig?>> config() async => const Success(LlmConfig());

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
    modes.add(context.mode);
    return modes.length == 1
        ? const BuddyReply(text: '先列出已知条件', truncated: true)
        : const BuddyReply(text: '补全后的提示');
  }
}

class _PageReuseHelpAi implements BuddyAi {
  String? materialId;
  final contexts = <BuddyContext>[];

  @override
  Future<Result<LlmConfig?>> config() async => const Success(LlmConfig());

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
    contexts.add(context);
    final materialId = this.materialId;
    if (contexts.length == 1 && materialId != null) {
      return BuddyReply(
        text: '先看第二页',
        truncated: true,
        providedSources: [
          CitationSource(
            materialId: materialId,
            pageNo: 2,
            content: '第 2 页原文',
            materialTitle: '概率讲义',
          ),
        ],
      );
    }
    return const BuddyReply(text: '补全后的提示');
  }
}

void main() {
  registerWorkspaceTests();

  testWidgets('重开学习页保留截断提示，使用原题与相同模式重试', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final ai = _RetryHelpAi();
    final server = FakeServer();
    await openApp(
      tester,
      ai: ai,
      size: const Size(390, 1400),
      serverClientFactory: (base) =>
          ServerClient(baseUrl: base, httpClient: server.client),
    );
    final id = (await tester.runAsync(() async {
      final account = scope!.accountServices.account;
      await account.setServerBaseUrl(syncTestServerUrl);
      await account.register(
        identifier: 'retry@example.test',
        password: syncTestPassword,
      );
      await scope!.settings.edit.saveConfig(const LlmConfig());
      expect(await scope!.modelReady(), isTrue);
      final id = await scope!.chat.learning.capture(stem: '原题：证明等式');
      await scope!.chat.learning.help(questionId: id, mode: BuddyMode.hint);
      return id;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => LearningPage(questionId: id)),
    );
    await settle(tester);
    expect(find.textContaining('先列出已知条件', findRichText: true), findsWidgets);
    expect(find.textContaining('回答被截断'), findsOneWidget);

    final retry = find.text('重试这次回答');
    for (var i = 0; i < 20 && retry.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await settle(tester);
    expect(ai.modes, [BuddyMode.hint, BuddyMode.hint]);
    final view = (await tester.runAsync(() => scope!.chat.learning.view(id)))!;
    expect(view.question.stem, '原题：证明等式');
    final helps = view.openAttempt!.helps;
    expect(helps.map((help) => help.content), ['先列出已知条件', '补全后的提示']);
    expect(helps.first.notices, [Notice.answerTruncated]);
    expect(helps.last.notices, isEmpty);
    expect(find.textContaining('补全后的提示', findRichText: true), findsWidgets);
    expect(retry, findsNothing);
  });

  testWidgets('重试求助接续上一次读到的材料页，原文按当前版本读取', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final ai = _PageReuseHelpAi();
    await openApp(tester, ai: ai, size: const Size(390, 1400));
    final reused = (await tester.runAsync(() async {
      final material = await scope!.testing.materials.create(title: '概率讲义');
      await scope!.testing.materials.addPage(
        materialId: material,
        pageNo: 2,
        content: '第 2 页原文',
      );
      ai.materialId = material;
      final id = await scope!.chat.learning.capture(stem: '原题：条件概率');
      await scope!.chat.learning.help(questionId: id, mode: BuddyMode.hint);
      final first = (await scope!.chat.learning.view(id)).openAttempt!.helps;
      expect(first.single.usedPages.single.pageNo, 2);
      await scope!.chat.learning.help(questionId: id, mode: BuddyMode.hint);
      return ai.contexts.last.materialHits
          .where((hit) => hit.pageNo == 2 && hit.materialId == material)
          .toList();
    }))!;
    expect(reused.single.materialTitle, '概率讲义');
    expect(reused.single.content, '第 2 页原文');
  });

  testWidgets('学习页可以进入先不看上次答案的独立重做', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '独立重做界面');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '旧的答案',
        isCorrect: true,
        independent: true,
      );
      return id;
    }))!;
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('复查（先不看上次）'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('复查（先不看上次）'));
    await settle(tester);

    await tester.scrollUntilVisible(
      find.textContaining('独立重做：'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('独立重做：'), findsOneWidget);
    expect(find.text('作答草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回时草稿保存失败会留在学习页', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '保存失败也要留住');
      await scope!.chat.learning.openAttempt(id);
      return id;
    }))!;
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
    await settle(tester);

    await tester.enterText(
      find.descendant(
        of: find.ancestor(
          of: find.text('答案或关键步骤'),
          matching: find.byType(forui.FTextField),
        ),
        matching: editableFields(),
      ),
      '还没保存下来的草稿',
    );
    await tester.runAsync(() async {
      await scope!.testing.db.execute('''
        CREATE TRIGGER fail_attempt_update BEFORE UPDATE ON attempt
        BEGIN
          SELECT RAISE(ABORT, '模拟草稿保存失败');
        END;
      ''');
    });

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);

    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.textContaining('保存草稿'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新打开学习页仍保持独立重做', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '重做状态要留下');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '上一次的答案',
        isCorrect: false,
        independent: true,
      );
      await scope!.chat.learning.openAttempt(id, independentRedo: true);
      return id;
    }))!;
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.textContaining('独立重做：'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('独立重做：'), findsOneWidget);
    expect(find.text('上一次的答案'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习页可以展开历次尝试的全部帮助', (tester) async {
    await openApp(tester, size: const Size(390, 1200));
    final id = (await tester.runAsync(() async {
      final conversationId = await scope!.chat.learning.capture(stem: '展开全部帮助');
      for (var index = 0; index < 3; index++) {
        await scope!.chat.learning.help(
          questionId: conversationId,
          mode: BuddyMode.hint,
        );
      }
      return conversationId;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => LearningPage(questionId: id)),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('查看全部 3 次帮助'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('· 提示：'), findsNWidgets(2));
    await tester.tap(find.text('查看全部 3 次帮助'));
    await settle(tester);
    expect(find.text('收起较早帮助'), findsOneWidget);
    expect(find.textContaining('· 提示：'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('作答草稿在页面里先保存再检查，提交后清空', (tester) async {
    await openApp(tester, size: const Size(390, 1200));
    final questionId = await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '写出条件概率公式'),
    );
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('继续作答'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('作答草稿'), findsOneWidget);

    final page = find.byType(LearningPage);
    await tester.enterText(
      find.descendant(of: page, matching: editableFields()).first,
      '先写出 P(A|B)=P(AB)/P(B)',
    );
    await tester.tap(find.text('做错了'));
    await tester.pump();
    await tester.tap(find.text('补充依据（可选）'));
    await settle(tester);
    final fields = find.descendant(of: page, matching: editableFields());
    await tester.ensureVisible(fields.at(2));
    await tester.enterText(fields.at(2), '卡在定义');
    await tester.ensureVisible(fields.at(3));
    await tester.enterText(fields.at(3), '与标准答案一致');
    await tester.ensureVisible(find.text('用了应用外帮助'));
    // 三选一改成 ZhixinSegmented，点击落在分段的 GestureDetector 上。
    await tester.tap(find.text('用了应用外帮助'));
    await tester.pump();

    // 点检查时先把整份草稿写进未提交尝试，回答再读这一份。
    await tester.ensureVisible(find.text('检查'));
    await tester.tap(find.text('检查').hitTestable());
    // 等本地检查结果或配置提示；本地兜底会顺带弹一次配置引导。
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (find.text('登录后使用学习帮助').evaluate().isNotEmpty) {
        break;
      }
      final result = find.textContaining('本地检查', findRichText: true);
      final busy = find.byType(forui.FProgress).evaluate().isNotEmpty;
      if (result.evaluate().isNotEmpty && !busy) break;
    }
    // 没有登录时本地回答会提示登录，先留在本地继续。
    if (find.text('登录后使用学习帮助').evaluate().isNotEmpty) {
      await tester.tap(find.text('继续本地使用'));
    }
    await settle(tester);
    expect(find.textContaining('本地检查', findRichText: true), findsWidgets);

    final draft = (await tester.runAsync(
      () => scope!.chat.learning.view(questionId!),
    ))!.openAttempt!;
    expect(draft.userAnswer, '先写出 P(A|B)=P(AB)/P(B)');
    expect(draft.isCorrect, isFalse);
    expect(draft.independent, isFalse);
    expect(draft.hintUsed, isTrue);
    expect(draft.feedback, '卡在定义');
    expect(draft.submitted, isFalse);
    final checkables = await tester.runAsync(
      () => scope!.testing.assessments.forAttempt(draft.id),
    );
    expect(checkables, hasLength(1));
    expect(checkables!.single.result, '与标准答案一致');

    // 提交直接使用页面上的草稿，不再经过提交弹窗；提交后编辑区清空。
    await tester.ensureVisible(find.text('提交作答'));
    await tester.tap(find.text('提交作答').hitTestable());
    await settle(tester);
    expect(find.text('记下这次作答'), findsNothing);
    final submitted = await tester.runAsync(
      () => scope!.testing.attempts.attemptById(draft.id),
    );
    expect(submitted!.submitted, isTrue);
    expect(submitted.userAnswer, '先写出 P(A|B)=P(AB)/P(B)');
    expect(submitted.isCorrect, isFalse);
    expect(submitted.hintUsed, isTrue);
    expect(submitted.feedback, '卡在定义');
    expect(
      (await tester.runAsync(() => scope!.chat.learning.view(questionId!)))!
          .openAttempt,
      isNull,
    );
    final cleared = tester
        .widget<EditableText>(
          find.descendant(of: page, matching: editableFields()).first,
        )
        .controller
        .text;
    expect(cleared, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连续点开始作答只建立一份草稿', (tester) async {
    await openApp(tester);
    final id = (await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '第 8 题求条件概率');
      return result.userMessage.conversationId;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    final button = find.text('开始作答');
    await tester.tap(button);
    await tester.tap(button);
    await settle(tester);

    expect(find.byType(LearningPage), findsOneWidget);
    final attempts = await tester.runAsync(
      () => scope!.testing.attempts.attemptsFor(id),
    );
    expect(attempts, hasLength(1));
    expect(attempts!.single.submitted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录页显示最近一次作答与模型判断', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '记录摘要');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '设 P(A|B)=P(AB)/P(B)',
        isCorrect: true,
        independent: true,
      );
      await scope!.testing.assessments.add(
        attemptId: attempt.id,
        kind: AssessmentKind.model,
        result: '步骤完整，结论正确',
        basis: '对照材料第 2 页',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await preview(tester, 'records');

    expect(find.textContaining('作答：设 P(A|B)'), findsOneWidget);
    expect(find.textContaining('自评：独立完成'), findsOneWidget);
    expect(find.textContaining('判断：步骤完整'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习页把最近讨论与作答放在同一条记录里', (tester) async {
    await openApp(tester);
    final id = (await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '讨论里的条件概率');
      return result.userMessage.conversationId;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => LearningPage(questionId: id)),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('同一条记录里的讨论'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('同一条记录里的讨论'), findsOneWidget);
    expect(find.textContaining('你：讨论里的条件概率'), findsOneWidget);
    expect(find.textContaining('搭子：'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录默认打开学习页，复查入口直接进入独立重做', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '记录复查题目');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '上次写下的答案',
        isCorrect: true,
        independent: true,
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('记录复查题目').first);
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('作答草稿'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.ellipsis).first);
    await settle(tester);
    await tester.tap(find.text('复查（先不看上次）'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('独立重做：'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('独立重做：'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录里可以清空一条记录，消息与作答一起删除', (tester) async {
    await openApp(tester);
    await tester.runAsync(() => scope!.chat.learning.capture(stem: '保留的题目'));
    final deletedImage = (await tester.runAsync(() async {
      final file = File('${scope!.paths.imagesDir}/deleted-record.jpg');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      return file;
    }))!;
    final conversationId = (await tester.runAsync(
      () => scope!.chat.discussion.createConversation(title: '要清空的记录'),
    ))!;
    await tester.runAsync(() async {
      await scope!.testing.conversations.append(
        conversationId,
        role: MessageRole.user,
        content: '这条记录会被清空',
        imagePaths: ['deleted-record.jpg'],
      );
      await scope!.testing.attempts.ensureOpenAttempt(conversationId);
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    expect(find.text('要清空的记录'), findsOneWidget);

    await tester.tap(find.byIcon(FLucideIcons.ellipsis).first);
    await settle(tester);
    await tester.tap(find.text('清空记录'));
    await settle(tester);
    await tester.tap(find.text('清空'));
    await settle(tester);

    expect(find.text('要清空的记录'), findsNothing);
    expect(await tester.runAsync(deletedImage.exists), isFalse);
    final conversations = await tester.runAsync(
      () => scope!.chat.discussion.records(),
    );
    expect(
      conversations!.any((record) => record.id == conversationId),
      isFalse,
    );
    expect(
      await tester.runAsync(
        () => scope!.testing.attempts.attemptsFor(conversationId),
      ),
      isEmpty,
    );
    final rows = await tester.runAsync(
      () => scope!.testing.conversations.questionRows(),
    );
    expect(rows!.single.question.stem, '保留的题目');
    expect(tester.takeException(), isNull);
  });
}
