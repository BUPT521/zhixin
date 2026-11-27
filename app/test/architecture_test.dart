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

  test('界面不直接依赖数据层', () {
    final lib = Directory('lib').absolute;
    final ui = Directory(p.join(lib.path, 'ui'));
    expect(ui.existsSync(), isTrue, reason: '界面层应保留在 lib/ui');

    final depending = <String, File>{};
    for (final source in _dartFiles(ui)) {
      final dependsOnData = _directives(source).any((uri) {
        final target = _resolveLocal(lib, source, uri);
        return target != null && _inside(lib, 'data', target);
      });
      if (dependsOnData) depending[p.basename(source.path)] = source;
    }

    for (final entry in depending.entries) {
      expect(
        _uiDataAllowlist.contains(entry.key),
        isTrue,
        reason: '${p.relative(entry.value.path)} 不能依赖数据层，值类型放 domain，行为经应用服务取用',
      );
    }
    for (final name in _uiDataAllowlist) {
      expect(
        depending.containsKey(name),
        isTrue,
        reason: '${p.join('lib', 'ui', name)} 已不再依赖数据层，请从 _uiDataAllowlist 删除',
      );
    }
  });

  test('安排页的两个页签是独立组件，不依赖页面本身', () {
    final lib = Directory('lib').absolute;
    final page = File(p.join(lib.path, 'ui', 'plan_page.dart'));
    expect(page.existsSync(), isTrue, reason: '安排页应保留页面壳');
    final source = page.readAsStringSync();
    expect(
      source.contains('CustomScrollView('),
      isFalse,
      reason: '页面壳只负责安排数据订阅与页签切换，列表与卡片放进各自的页签组件',
    );

    const tabs = {
      'plan_items_tab.dart': 'PlanItemsTab',
      'plan_goals_tab.dart': 'PlanGoalsTab',
    };
    final pagePath = p.normalize(page.absolute.path);
    for (final entry in tabs.entries) {
      final tab = File(p.join(lib.path, 'ui', entry.key));
      expect(tab.existsSync(), isTrue, reason: '安排页应拆出 ${entry.key}');
      final directives = _directives(tab);
      expect(
        directives.any((uri) => uri.endsWith('/plan_page.dart')),
        isFalse,
        reason: '${entry.key} 不能依赖页面，页面单向依赖页签',
      );
      expect(
        tab.readAsStringSync().contains('class ${entry.value}'),
        isTrue,
        reason: '${entry.key} 应提供 ${entry.value}',
      );
      for (final target in _reachableFiles(lib, tab)) {
        expect(
          p.equals(p.normalize(target.absolute.path), pagePath),
          isFalse,
          reason: '${entry.key} 不能通过其他文件绕回页面',
        );
      }
    }
  });

  test('插件目录不读数据层与界面，也不持有数据库连接', () {
    final lib = Directory('lib').absolute;
    final plugins = Directory(p.join(lib.path, 'plugins'));
    expect(plugins.existsSync(), isTrue, reason: 'M1 应建立 lib/plugins 目录');
    final sources = _dartFiles(plugins);
    expect(sources, isNotEmpty);

    for (final source in sources) {
      for (final target in _reachableFiles(lib, source)) {
        final path = p.normalize(target.absolute.path);
        for (final forbidden in ['data', 'ui']) {
          expect(
            p.isWithin(p.join(lib.path, forbidden), path),
            isFalse,
            reason: '${source.path} 不能依赖 ${target.path}',
          );
        }
        final directives = _directives(target);
        expect(
          directives.where(
            (uri) =>
                uri.startsWith('package:sqlite3') ||
                uri.startsWith('package:drift'),
          ),
          isEmpty,
          reason: '${target.path} 不能打开数据库或持有连接，写入只能由应用服务完成',
        );
        expect(
          directives.where(
            (uri) =>
                uri.startsWith('package:flutter') ||
                uri.startsWith('package:path_provider/'),
          ),
          isEmpty,
          reason: '${target.path} 不依赖界面与平台插件，插件代码保持纯 Dart',
        );
      }
    }
  });

  test('应用根只公开服务与基础句柄，仓库、库连接与测试入口不对外', () {
    final lib = Directory('lib').absolute;
    final scopeLines = File(p.join(lib.path, 'app_scope.dart'))
        .readAsLinesSync();
    for (final name in _repositoryMembers) {
      final declaration = RegExp(
        '^\\s+(?:late\\s+)?(?:final\\s+)?[A-Z]\\w*'
        '(?:<[^>]*>)?\\s+$name\\s*[;=]',
      );
      expect(
        scopeLines.where(declaration.hasMatch),
        isEmpty,
        reason: 'AppScopeState 不能公开仓库字段 $name；页面经 services 与基础句柄取用',
      );
    }
    final testingEntry = scopeLines.where(
      RegExp(r'^\s+(?:late\s+final\s+)?AppScopeTesting\s+testing\b').hasMatch,
    );
    expect(testingEntry, hasLength(1), reason: '测试装配入口只能有一个');

    for (final source in _dartFiles(lib)) {
      expect(
        source.readAsStringSync().contains('.testing.'),
        isFalse,
        reason: '${source.path} 不能读测试装配入口，页面与服务只经服务取数据',
      );
    }
  });
}

/// 界面层直接依赖数据层的文件白名单，只减不增。
///
/// 界面不直接依赖数据层：页面需要的值类型放在 `domain/models`，行为经应用服务取用，
/// 目标与进度见 `docs/分层整改清单与提示词.md`。这份清单记录搬家还没做完的部分，
/// 不是允许继续新增依赖的许可；每去掉一处引用，就把文件名删掉，用例会强制清单只减不增。
const _uiDataAllowlist = <String>{
  'account_page.dart',
  'cloud_backup_page.dart',
  'data_version_page.dart',
  'embedding_settings_page.dart',
  'feedback_page.dart',
  'integrity_check.dart',
  'mine_page.dart',
  'settings_page.dart',
  'update_notice.dart',
};

/// 曾经公开在 [AppScopeState] 上的仓库与连接字段；现在只在测试入口里露出。
const _repositoryMembers = [
  'db',
  'gate',
  'runtime',
  'conversations',
  'attempts',
  'tasks',
  'memories',
  'studyRecords',
  'assessments',
  'materials',
  'studyPlans',
];

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
