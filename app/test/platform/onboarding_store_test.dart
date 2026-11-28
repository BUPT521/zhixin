import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/platform/onboarding_store.dart';
import 'package:zhixin/ui/onboarding_controller.dart';

/// 首次启动引导的设备级状态：读写、文件缺失、内容损坏、须知版本升级与步骤续接。
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-onboarding-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('没有文件时四项都是默认值', () async {
    final record = await OnboardingStore(directory.path).read();
    expect(record.completed, isFalse);
    expect(record.termsVersion, 0);
    expect(record.agreed, isFalse);
    expect(record.stage, OnboardingStage.login);
    expect(record.consentCurrent, isFalse);
  });

  test('写入之后能原样读回四项状态', () async {
    final store = OnboardingStore(directory.path);
    await store.write(
      const OnboardingRecord(
        completed: true,
        termsVersion: kTermsVersion,
        agreed: true,
        stage: OnboardingStage.appearance,
      ),
    );
    final record = await store.read();
    expect(record.completed, isTrue);
    expect(record.termsVersion, kTermsVersion);
    expect(record.agreed, isTrue);
    expect(record.stage, OnboardingStage.appearance);
    expect(record.consentCurrent, isTrue);

    // 四项分开写：完成标记写回假时，同意的版本、是否同意与步骤不受影响。
    await store.write(record.copyWith(completed: false, agreed: false));
    final partial = await store.read();
    expect(partial.completed, isFalse);
    expect(partial.termsVersion, kTermsVersion);
    expect(partial.agreed, isFalse);
    expect(partial.stage, OnboardingStage.appearance);
    expect(partial.consentCurrent, isFalse);
  });

  test('内容损坏时按未完成处理，不把坏文件当成已经同意', () async {
    final store = OnboardingStore(directory.path);
    await File(store.path).writeAsString('{这不是 json');
    final record = await store.read();
    expect(record.completed, isFalse);
    expect(record.termsVersion, 0);
    expect(record.agreed, isFalse);
    expect(record.stage, OnboardingStage.login);

    // 字段类型不对时同样回到默认值；步骤只认写过的两个名字。
    await File(store.path).writeAsString(
      '{"completed": 1, "termsVersion": "三", "agreed": "yes", "stage": "外观"}',
    );
    final wrongTypes = await store.read();
    expect(wrongTypes.completed, isFalse);
    expect(wrongTypes.termsVersion, 0);
    expect(wrongTypes.agreed, isFalse);
    expect(wrongTypes.stage, OnboardingStage.login);
  });

  test('须知版本升级之后在首页补一次同意', () async {
    final store = OnboardingStore(directory.path);
    await store.write(
      OnboardingRecord(
        completed: true,
        termsVersion: kTermsVersion - 1,
        agreed: true,
      ),
    );
    final record = await store.read();
    expect(record.completed, isTrue);
    expect(record.termsVersion, kTermsVersion - 1);
    expect(record.agreed, isTrue);
    expect(record.consentCurrent, isFalse, reason: '同意的是旧版本');

    expect(
      OnboardingController.entryFor(record, existingUser: false),
      OnboardingEntry.termsOnly,
    );
  });

  test('完成当前版本的引导之后直接进首页', () async {
    final record = OnboardingRecord(
      completed: true,
      termsVersion: kTermsVersion,
      agreed: true,
    );
    expect(
      OnboardingController.entryFor(record, existingUser: false),
      OnboardingEntry.home,
    );
    expect(
      OnboardingController.entryFor(record, existingUser: true),
      OnboardingEntry.home,
      reason: '老用户判断不改变已经完成的状态',
    );
  });

  test('老用户没有完成标记时在首页补同意，全新安装走完整引导', () async {
    const fresh = OnboardingRecord();
    expect(
      OnboardingController.entryFor(fresh, existingUser: true),
      OnboardingEntry.termsOnly,
    );
    expect(
      OnboardingController.entryFor(fresh, existingUser: false),
      OnboardingEntry.full,
    );
  });

  test('先在本机用之前先写盘，重开之后从外观看起', () async {
    final store = OnboardingStore(directory.path);
    final controller = OnboardingController(
      store: store,
      entry: OnboardingEntry.full,
      record: const OnboardingRecord(),
      signedIn: false,
      telemetryEnabled: true,
    );
    addTearDown(controller.dispose);
    expect(controller.stage, OnboardingStage.login);

    await controller.useLocally();
    expect(controller.stage, OnboardingStage.appearance);
    expect(
      (await store.read()).stage,
      OnboardingStage.appearance,
      reason: '登录会在请求途中换空间，步骤不能等登录返回再写',
    );

    final saved = await store.read();
    final reopened = OnboardingController(
      store: store,
      entry: OnboardingController.entryFor(saved, existingUser: false),
      record: saved,
      signedIn: false,
      telemetryEnabled: true,
    );
    addTearDown(reopened.dispose);
    expect(reopened.stage, OnboardingStage.appearance);
  });

  test('重建之后已经登录时从外观继续，没有登录时仍停在登录页', () async {
    final store = OnboardingStore(directory.path);
    final record = OnboardingRecord(
      termsVersion: kTermsVersion,
      agreed: true,
      stage: OnboardingStage.login,
    );

    final signedIn = OnboardingController(
      store: store,
      entry: OnboardingEntry.full,
      record: record,
      signedIn: true,
      telemetryEnabled: true,
    );
    addTearDown(signedIn.dispose);
    expect(signedIn.stage, OnboardingStage.appearance);

    final signedOut = OnboardingController(
      store: store,
      entry: OnboardingEntry.full,
      record: record,
      signedIn: false,
      telemetryEnabled: true,
    );
    addTearDown(signedOut.dispose);
    expect(signedOut.stage, OnboardingStage.login);
  });

  test('先在本机用只跳过登录，没有同意过才记下只在本机', () async {
    final store = OnboardingStore(directory.path);
    // 已经同意的用户点“先在本机用”只是这次不登录，同意状态不能撤掉。
    final consented = OnboardingController(
      store: store,
      entry: OnboardingEntry.full,
      record: OnboardingRecord(termsVersion: kTermsVersion, agreed: true),
      signedIn: false,
      telemetryEnabled: true,
    );
    addTearDown(consented.dispose);
    await consented.useLocally();
    expect((await store.read()).stage, OnboardingStage.appearance);
    expect((await store.read()).agreed, isTrue);
    expect((await store.read()).termsVersion, kTermsVersion);

    // 没有同意过的记下当前版本已经回答过、没有同意。
    final freshDir = await Directory.systemTemp.createTemp(
      'zhixin-onboarding-fresh-',
    );
    addTearDown(() async {
      if (await freshDir.exists()) await freshDir.delete(recursive: true);
    });
    final freshStore = OnboardingStore(freshDir.path);
    final fresh = OnboardingController(
      store: freshStore,
      entry: OnboardingEntry.full,
      record: const OnboardingRecord(),
      signedIn: false,
      telemetryEnabled: true,
    );
    addTearDown(fresh.dispose);
    await fresh.useLocally();
    expect((await freshStore.read()).stage, OnboardingStage.appearance);
    expect((await freshStore.read()).agreed, isFalse);
    expect((await freshStore.read()).termsVersion, kTermsVersion);
  });

  test('选择不同意时没有登录这一步', () async {
    final store = OnboardingStore(directory.path);
    final declined = OnboardingController(
      store: store,
      entry: OnboardingEntry.full,
      record: OnboardingRecord(termsVersion: kTermsVersion, agreed: false),
      signedIn: false,
      telemetryEnabled: true,
    );
    addTearDown(declined.dispose);
    expect(declined.stage, OnboardingStage.appearance);
  });
}
