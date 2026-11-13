import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/platform/theme_mode_store.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-theme-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('外观默认跟随系统，选择后写进本机文件', () async {
    final store = ThemeModeStore(directory.path);
    final controller = await ThemeModeController.load(store);
    expect(controller.value, ThemeMode.system);

    await controller.select(ThemeMode.dark);
    expect(controller.value, ThemeMode.dark);
    expect(await store.read(), 'dark');
    expect((await ThemeModeController.load(store)).value, ThemeMode.dark);

    await controller.select(ThemeMode.light);
    expect((await ThemeModeController.load(store)).value, ThemeMode.light);
  });

  test('文件内容不认识时回到跟随系统', () async {
    await File(ThemeModeStore(directory.path).path).writeAsString('midnight');

    final controller = await ThemeModeController.load(
      ThemeModeStore(directory.path),
    );
    expect(controller.value, ThemeMode.system);
  });

  test('没有保存动作时只换当前外观', () async {
    final controller = ThemeModeController();

    await controller.select(ThemeMode.dark);

    expect(controller.value, ThemeMode.dark);
  });
}
