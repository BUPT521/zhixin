import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/platform/onboarding_store.dart';
import 'package:zhixin/ui/onboarding_controller.dart';

/// 首次启动引导的设备级状态：读写、文件缺失、内容损坏与须知版本升级。
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-onboarding-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('没有文件时三项都是默认值', () async {
    final record = await OnboardingStore(directory.path).read();
    expect(record.completed, isFalse);
    expect(record.termsVersion, 0);
    expect(record.agreed, isFalse);
    expect(record.consentCurrent, isFalse);
  });

  test('写入之后能原样读回三项状态', () async {
    final store = OnboardingStore(directory.path);
    await store.write(
      const OnboardingRecord(
        completed: true,
        termsVersion: kTermsVersion,
        agreed: true,
      ),
    );
    final record = await store.read();
    expect(record.completed, isTrue);
    expect(record.termsVersion, kTermsVersion);
    expect(record.agreed, isTrue);
    expect(record.consentCurrent, isTrue);

    // 三项分开写：完成标记写回假时，同意的版本与是否同意不受影响。
    await store.write(
      record.copyWith(completed: false, agreed: false),
    );
    final partial = await store.read();
    expect(partial.completed, isFalse);
    expect(partial.termsVersion, kTermsVersion);
    expect(partial.agreed, isFalse);
    expect(partial.consentCurrent, isFalse);
  });

  test('内容损坏时按未完成处理，不把坏文件当成已经同意', () async {
    final store = OnboardingStore(directory.path);
    await File(store.path).writeAsString('{这不是 json');
    final record = await store.read();
    expect(record.completed, isFalse);
    expect(record.termsVersion, 0);
    expect(record.agreed, isFalse);

    // 字段类型不对时同样回到默认值。
    await File(store.path).writeAsString(
      '{"completed": 1, "termsVersion": "三", "agreed": "yes"}',
    );
    final wrongTypes = await store.read();
    expect(wrongTypes.completed, isFalse);
    expect(wrongTypes.termsVersion, 0);
    expect(wrongTypes.agreed, isFalse);
  });

  test('须知版本升级之后需要重新同意，只补第一步', () async {
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

  test('老用户没有完成标记时只补第一步，全新安装走完整引导', () async {
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
}
