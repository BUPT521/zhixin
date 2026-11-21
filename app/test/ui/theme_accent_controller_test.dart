import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/platform/theme_accent_store.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-accent-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('主题色默认蓝色，选择后写进本机文件', () async {
    final store = ThemeAccentStore(directory.path);
    final controller = await ThemeAccentController.load(store);
    expect(controller.value, ZhixinAccent.blue);

    await controller.select(ZhixinAccent.violet);
    expect(controller.value, ZhixinAccent.violet);
    expect(await store.read(), 'violet');
    expect(
      (await ThemeAccentController.load(store)).value,
      ZhixinAccent.violet,
    );

    await controller.select(ZhixinAccent.graphite);
    expect(
      (await ThemeAccentController.load(store)).value,
      ZhixinAccent.graphite,
    );
  });

  test('六个主题色都能存下来，再读回来是同一个', () async {
    final store = ThemeAccentStore(directory.path);
    for (final accent in ZhixinAccent.values) {
      await store.write(accent.name);
      expect((await ThemeAccentController.load(store)).value, accent);
    }
  });

  test('文件内容不认识时回到蓝色', () async {
    await File(ThemeAccentStore(directory.path).path).writeAsString('teal');

    final controller = await ThemeAccentController.load(
      ThemeAccentStore(directory.path),
    );
    expect(controller.value, ZhixinAccent.blue);
  });

  test('文件为空时回到蓝色', () async {
    await File(ThemeAccentStore(directory.path).path).writeAsString('  ');

    final controller = await ThemeAccentController.load(
      ThemeAccentStore(directory.path),
    );
    expect(controller.value, ZhixinAccent.blue);
  });

  test('没有保存动作时只换当前主题色', () async {
    final controller = ThemeAccentController();

    await controller.select(ZhixinAccent.rose);

    expect(controller.value, ZhixinAccent.rose);
  });

  test('主题色与深浅色各存一个文件，互不覆盖', () async {
    final mode = File('${directory.path}/theme_mode');
    await mode.writeAsString('dark');
    final store = ThemeAccentStore(directory.path);

    await store.write('moss');

    expect(store.path, isNot(mode.path));
    expect(await mode.readAsString(), 'dark');
    expect((await ThemeAccentController.load(store)).value, ZhixinAccent.moss);
  });
}
