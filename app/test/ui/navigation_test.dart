import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 导航中间层的边界：页面只经由 `navigation.dart` 打开另一个页面。
///
/// 页面互相 import 会让打开方式散到各页，换路由或换过渡要改十几处；这里把
/// 约定写成检查，新增页面时要么给出导航入口，要么只作为底栏页由 [HomeShell]
/// 拼装。
void main() {
  final ui = Directory('lib/ui').absolute;
  final pages = _pageFiles(ui);
  final navigation = p.join(ui.path, 'navigation.dart');
  final pagePaths = {for (final page in pages) page.path};

  test('页面互相之间只 import navigation.dart', () {
    expect(pages, isNotEmpty);
    for (final page in pages) {
      final name = p.basename(page.path);
      final allowed = name == 'home_shell.dart'
          ? {navigation, ..._tabPages(ui)}
          : {navigation};
      for (final import in _localImports(page)) {
        if (!pagePaths.contains(import)) continue;
        expect(
          allowed.contains(import),
          isTrue,
          reason:
              '$name 不能直接 import ${p.basename(import)}，页面打开走 navigation.dart',
        );
      }
    }
  });

  test('推入页面的路由只在 navigation.dart 里构造', () {
    for (final file in ui.listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (p.equals(file.path, navigation)) continue;
      expect(
        file.readAsStringSync().contains('MaterialPageRoute'),
        isFalse,
        reason: '${p.basename(file.path)} 不应自己构造路由，改用 navigation.dart 的入口',
      );
    }
  });

  test('除底栏页外，每个页面都有导航入口', () {
    final source = File(navigation).readAsStringSync();
    final tabs = _tabPages(ui);
    for (final page in pages) {
      if (p.basename(page.path) == 'home_shell.dart') continue;
      if (tabs.contains(page.path)) continue;
      final className = _pageClass(page);
      expect(
        source.contains("import '${p.basename(page.path)}';"),
        isTrue,
        reason: '${p.basename(page.path)} 没有导航入口，页面之间会重新互相 import',
      );
      expect(
        className == null || source.contains('$className('),
        isTrue,
        reason: '${p.basename(page.path)} 的导航入口没有构造页面',
      );
    }
  });
}

/// 页面文件：文件名以 `_page.dart` 结尾，加上拼装三栏的 `home_shell.dart`。
List<File> _pageFiles(Directory ui) => ui
    .listSync()
    .whereType<File>()
    .where(
      (file) =>
          file.path.endsWith('_page.dart') ||
          p.basename(file.path) == 'home_shell.dart',
    )
    .toList(growable: false);

/// 底栏三栏的页面：由 [HomeShell] 常驻拼装，不走推入入口。
List<String> _tabPages(Directory ui) => [
  p.join(ui.path, 'now_page.dart'),
  p.join(ui.path, 'records_page.dart'),
  p.join(ui.path, 'plan_page.dart'),
];

/// 文件里 import 到的同目录 dart 文件。
List<String> _localImports(File file) {
  final result = <String>[];
  final pattern = RegExp(r"^import '([a-z0-9_]+\.dart)';", multiLine: true);
  for (final match in pattern.allMatches(file.readAsStringSync())) {
    result.add(p.join(file.parent.path, match.group(1)!));
  }
  return result;
}

/// 页面文件里第一个页面类的名字；没有页面类时返回空。
String? _pageClass(File file) {
  final match = RegExp(r'class (\w+Page) extends (?:Stateful|Stateless)Widget')
      .firstMatch(file.readAsStringSync());
  return match?.group(1);
}
