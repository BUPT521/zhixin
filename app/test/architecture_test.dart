import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 依赖方向只指向更稳定的层；平台适配集中在 composition root 与 platform。
void main() {
  test('domain、AI、data 与 application 的依赖保持单向', () {
    final lib = Directory('lib').absolute;
    final files = _dartFiles(lib);
    final boundaries = {
      'domain': ['ai', 'application', 'data', 'platform', 'ui'],
      'ai': ['application', 'data', 'platform', 'ui'],
      'data': ['application', 'platform', 'ui'],
      'application': ['ui', 'platform'],
    };

    for (final entry in boundaries.entries) {
      final sourceFiles = files
          .where((file) => _inside(lib, entry.key, file))
          .toList(growable: false);
      for (final source in sourceFiles) {
        if (entry.key == 'application') {
          expect(
            _directives(source)
                .where((uri) => uri.startsWith('package:sqlite3')),
            isEmpty,
            reason: '${source.path} 应通过数据层访问数据库',
          );
        }
        final reachable = _reachableFiles(lib, source);
        for (final target in reachable) {
          for (final forbidden in entry.value) {
            expect(
              _inside(lib, forbidden, target),
              isFalse,
              reason: '${source.path} 不能依赖 ${target.path}',
            );
          }
          final directives = _directives(target);
          expect(
            directives.where(_isPlatformPackage),
            isEmpty,
            reason: '${target.path} 不应依赖界面或平台插件',
          );
        }
      }
    }
  });

  test('周视图只接收传入的数据与回调，不直接读业务数据', () {
    final lib = Directory('lib').absolute;
    final view = File(p.join(lib.path, 'ui', 'plan_week_view.dart'));
    expect(view.existsSync(), isTrue, reason: '安排页的周视图应拆成单独组件');

    final scopeFile = p.normalize(p.join(lib.path, 'app_scope.dart'));
    for (final target in _reachableFiles(lib, view)) {
      final path = p.normalize(target.absolute.path);
      expect(
        p.equals(path, scopeFile),
        isFalse,
        reason: '${view.path} 不能通过 AppScope 取数据，周视图只接收调用方传入的周数据',
      );
      expect(
        p.isWithin(p.join(lib.path, 'data', 'repository'), path),
        isFalse,
        reason: '${view.path} 不能直接读仓库，读写留给安排页通过服务完成',
      );
      expect(
        p.isWithin(p.join(lib.path, 'application'), path),
        isFalse,
        reason: '${view.path} 不调用应用服务，选周读取与写入留在安排页',
      );
      expect(
        path.endsWith('_page.dart'),
        isFalse,
        reason: '${view.path} 不能依赖页面，页面单向依赖周视图',
      );
    }
  });
}

bool _isPlatformPackage(String uri) =>
    uri.startsWith('package:flutter') ||
    uri.startsWith('package:material_ui/') ||
    uri.startsWith('package:path_provider/') ||
    uri.startsWith('package:image_picker/') ||
    uri.startsWith('package:file_picker/');

List<File> _dartFiles(Directory lib) => lib
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList(growable: false);

bool _inside(Directory lib, String layer, File file) =>
    p.isWithin(p.join(lib.path, layer), file.absolute.path);

Set<File> _reachableFiles(Directory lib, File root) {
  final visited = <String>{};
  final pending = <File>[root];
  final result = <File>{};
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    final path = p.normalize(file.absolute.path);
    if (!visited.add(path)) continue;
    result.add(file);
    for (final uri in _directives(file)) {
      final target = _resolveLocal(lib, file, uri);
      if (target != null && target.existsSync()) pending.add(target);
    }
  }
  return result;
}

List<String> _directives(File file) {
  final result = <String>[];
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
      continue;
    }
    final firstQuote = line.indexOf("'");
    if (firstQuote < 0) continue;
    final secondQuote = line.indexOf("'", firstQuote + 1);
    if (secondQuote < 0) continue;
    result.add(line.substring(firstQuote + 1, secondQuote));
  }
  return result;
}

File? _resolveLocal(Directory lib, File source, String uri) {
  if (uri.startsWith('package:zhixin/')) {
    return File(p.join(lib.path, uri.substring('package:zhixin/'.length)));
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  return File.fromUri(source.absolute.uri.resolve(uri));
}
