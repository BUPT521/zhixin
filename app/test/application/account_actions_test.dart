// 账号页的操作状态、顺序与影响说明只有一份（审查条目 A30）。
//
// 八类流程原先共用页面上的一个 `_busy` 与一个 `_codeSent`：换一类操作会把所有按钮
// 一起禁用，两类验证码又共用一个“已经发出”的标记。用例核对：
// 1. 两类验证码各自记“已经发出”，发送之后进入重发冷却；
// 2. 输入没过校验时只给一句提示，不调用服务端；
// 3. 失败说明按操作取名（动作名、诊断种类、保留状态与下一步），页面只渲染。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/account_actions.dart';
import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/device_preferences_store.dart';
import 'package:zhixin/data/cloud/sync_preferences_store.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/asset_store.dart';

import '../support/fake_server.dart';
import '../support/test_db.dart';

void main() {
  const email = 'account-actions@example.com';
  const password = 'password123';

  late FakeServer server;
  late Directory dir;
  late AccountService account;
  late AccountActions actions;
  late String identityId;

  setUp(() async {
    server = FakeServer();
    dir = await Directory.systemTemp.createTemp('zhixin_account_actions');
    account = AccountService(
      store: AccountStore(MemorySecretStore()),
      devicePreferences: DevicePreferencesStore(filesDir: dir.path),
      syncPreferences: SyncPreferencesStore(filesDir: dir.path),
      clientFactory: (baseUrl) =>
          ServerClient(baseUrl: baseUrl, httpClient: server.client),
    );
    addTearDown(account.dispose);
    await account.setServerBaseUrl('http://server.test');
    await account.register(identifier: email, password: password);
    identityId = (await account.refreshAccount()).profile!.identities.single.id;
    final rig = await openTestRig();
    addTearDown(rig.close);
    final sync = SyncService(
      account: account,
      syncPreferences: account.syncPreferences,
      revisions: rig.revisions,
      engine: rig.engine,
      database: rig.db,
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      assets: rig.engine.assets,
      cache: AttachmentCache(filesDir: () => rig.filesDir),
      clock: rig.engine.clock,
      recordFailure: (error, stack, {required String kind}) {},
    );
    addTearDown(sync.dispose);
    actions = AccountActions(
      account: account,
      sync: sync,
      clearAllData: (_) async {},
      deleteLocalSpace: (_) async {},
    );
    addTearDown(actions.dispose);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('两类验证码各自记“已经发出”，发送之后按服务端间隔进入重发冷却', () async {
    final result = await actions.sendIdentityCode(
      identityId: identityId,
      identifier: email,
    );

    expect(result.failed, isFalse);
    expect(result.message, contains('验证码已经发到 $email'));
    expect(
      actions.state.codeSentFor(AccountAction.sendIdentityCode),
      isTrue,
      reason: '确认登录方式的验证码已经发出',
    );
    expect(
      actions.state.codeSentFor(AccountAction.sendResetCode),
      isFalse,
      reason: '两类验证码不再共用同一个“已经发出”的标记',
    );
    expect(actions.state.cooling, isTrue);
    expect(actions.state.resendWait, AccountActions.resendCooldownSeconds);
  });

  test('切换登录与找回密码时分别清掉冷却与验证码标记，操作状态随之复位', () async {
    await actions.sendIdentityCode(identityId: identityId, identifier: email);
    expect(actions.state.cooling, isTrue);

    actions.begin(AccountAction.sendResetCode);
    expect(actions.state.busy, isTrue);
    expect(actions.state.running, AccountAction.sendResetCode);
    actions.end();
    expect(actions.state.busy, isFalse);
    expect(
      actions.state.codeSentFor(AccountAction.sendIdentityCode),
      isTrue,
      reason: '结束一次流程不改验证码状态',
    );

    actions.clearCooldown();
    expect(actions.state.cooling, isFalse);
    expect(
      actions.state.codeSentFor(AccountAction.sendIdentityCode),
      isTrue,
      reason: '只清冷却，不清“验证码已经发出”',
    );

    actions.clearCode();
    expect(actions.state.codeSent, isNull);
  });

  test('输入没过校验时只给一句提示，不调用服务端', () async {
    final result = await actions.resetPassword(
      identifier: email,
      code: '123',
      password: password,
    );

    expect(result.failed, isTrue);
    expect(result.message, '填写邮件里的六位验证码');
    expect((await account.snapshot()).profile, isNotNull, reason: '校验没过不改登录状态');
  });

  test('确认登录方式之后清掉验证码标记，并要求重读账号摘要', () async {
    await actions.sendIdentityCode(identityId: identityId, identifier: email);
    final code = server.codeFor(email, 'verify_contact')!;

    final result = await actions.confirmIdentity(
      identityId: identityId,
      kindLabel: '邮箱',
      code: code,
    );

    expect(result.failed, isFalse);
    expect(result.reload, isTrue);
    expect(result.message, contains('邮箱已经确认'));
    expect(actions.state.codeSent, isNull);
    expect(actions.state.cooling, isFalse);
  });

  test('未确认登录方式的账号删除之前不读余额', () async {
    expect(
      await actions.remainingPointsBeforeDelete(contactVerified: false),
      isNull,
    );
  });

  test('影响说明按操作取名，同一句话只有一处', () {
    for (final action in AccountAction.values) {
      final copy = accountActionCopy(action);
      expect(copy.action, isNotEmpty);
      expect(copy.kind, isNotEmpty);
      expect(copy.kept, isNotEmpty);
      expect(copy.next, isNotEmpty);
    }
    expect(
      accountActionCopy(AccountAction.sync).kind,
      'account_sync',
      reason: '诊断种类沿用原来的取值，排障记录不变',
    );
  });
}
