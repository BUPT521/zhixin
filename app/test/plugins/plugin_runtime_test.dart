import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/plugins/persona/persona.dart';
import 'package:zhixin/plugins/persona/persona_catalog.dart';
import 'package:zhixin/plugins/persona/persona_plugin.dart';
import 'package:zhixin/plugins/runtime/plugin.dart';
import 'package:zhixin/plugins/runtime/plugin_access.dart';
import 'package:zhixin/plugins/runtime/plugin_manifest.dart';
import 'package:zhixin/plugins/runtime/plugin_runtime.dart';

import '../support/plugin_memory_store.dart';

PluginManifest _capabilityManifest({
  String id = 'probe',
  PluginPermissions permissions = PluginPermissions.none,
}) => PluginManifest(
  id: id,
  name: '探测插件',
  version: '1.0.0',
  description: '测试用的能力插件。',
  kind: PluginKind.capability,
  permissions: permissions,
);

/// 假的能力插件：启动时依次调用四个门面，把失败收集起来。
class _ProbePlugin implements FirstPartyPlugin {
  _ProbePlugin({PluginManifest? manifest})
    : manifest = manifest ?? _capabilityManifest();

  @override
  final PluginManifest manifest;

  int starts = 0;
  final List<Object> failures = [];

  @override
  Future<void> start(PluginAccess access) async {
    starts++;
    final calls = <Future<Object?> Function()>[
      () => access.network.fetch('https://api.example.com/timetable'),
      () => access.readData.read(scope: 'timetable'),
      () => access.submitDraft.submit(writeType: 'timetable', draft: const {}),
      () => access.callModel.complete('这几个字'),
    ];
    for (final call in calls) {
      try {
        await call();
      } catch (error) {
        failures.add(error);
      }
    }
  }
}

/// 启动就失败的插件：启停状态不应写成新的值。
class _BrokenPlugin implements FirstPartyPlugin {
  @override
  PluginManifest get manifest => _capabilityManifest(id: 'broken');

  @override
  Future<void> start(PluginAccess access) async => throw StateError('启动失败');
}

class _CountingNetwork implements PluginNetworkBackend {
  int calls = 0;

  @override
  Future<Object?> fetch(Uri url) async {
    calls++;
    return null;
  }
}

class _CountingReads implements PluginDataReadBackend {
  int calls = 0;

  @override
  Future<Object?> read({
    required String scope,
    required Map<String, Object?> query,
  }) async {
    calls++;
    return null;
  }
}

class _CountingDrafts implements PluginDraftSubmitBackend {
  int calls = 0;

  @override
  Future<String> submit({
    required String writeType,
    required Map<String, Object?> draft,
  }) async {
    calls++;
    return 'commit';
  }
}

class _CountingModel implements PluginModelCallBackend {
  int calls = 0;

  @override
  Future<String> complete({required String prompt}) async {
    calls++;
    return '回答';
  }
}

void main() {
  group('注册与启停', () {
    test('清单不合格、标识重复与多个人格插件都拒绝注册', () {
      expect(
        () => PluginRuntime(
          store: MemoryPluginMetadataStore(),
          personas: PersonaCatalog(store: MemoryPluginMetadataStore()),
          plugins: [_ProbePlugin(manifest: _capabilityManifest(id: 'Bad'))],
        ),
        throwsA(
          isA<PluginRegistrationException>().having(
            (error) => error.messages.join('；'),
            'messages',
            contains('插件标识'),
          ),
        ),
      );

      final probe = _ProbePlugin();
      expect(
        () => PluginRuntime(
          store: MemoryPluginMetadataStore(),
          personas: PersonaCatalog(store: MemoryPluginMetadataStore()),
          plugins: [probe, _ProbePlugin()],
        ),
        throwsA(
          isA<PluginRegistrationException>().having(
            (error) => error.messages.join('；'),
            'messages',
            contains('标识重复'),
          ),
        ),
      );

      final firstCatalog = PersonaCatalog(store: MemoryPluginMetadataStore());
      final secondCatalog = PersonaCatalog(store: MemoryPluginMetadataStore());
      expect(
        () => PluginRuntime(
          store: MemoryPluginMetadataStore(),
          personas: firstCatalog,
          plugins: [PersonaPlugin(firstCatalog), PersonaPlugin(secondCatalog)],
        ),
        throwsA(isA<PluginRegistrationException>()),
      );
    });

    test('未知插件标识在查询、启停与权限判断时都拒绝', () async {
      final store = MemoryPluginMetadataStore();
      final catalog = PersonaCatalog(store: store);
      final runtime = PluginRuntime(
        store: store,
        personas: catalog,
        plugins: [PersonaPlugin(catalog)],
      );
      await runtime.load();

      expect(() => runtime.isEnabled('nope'), throwsA(isA<PluginNotFound>()));
      expect(() => runtime.byId('nope'), throwsA(isA<PluginNotFound>()));
      expect(
        () => runtime.byId('nope').manifest.permissions,
        throwsA(isA<PluginNotFound>()),
      );
      await expectLater(
        runtime.setEnabled('nope', true),
        throwsA(isA<PluginNotFound>()),
      );
    });

    test('启停状态写在 app_meta，重新装载后按状态启动', () async {
      final store = MemoryPluginMetadataStore({pluginEnabledKey('probe'): '0'});
      final probe = _ProbePlugin();
      final catalog = PersonaCatalog(store: store);
      final runtime = PluginRuntime(
        store: store,
        personas: catalog,
        plugins: [probe, PersonaPlugin(catalog)],
      );
      await runtime.load();

      expect(runtime.isEnabled('probe'), isFalse);
      expect(probe.starts, 0);

      await runtime.setEnabled('probe', true);
      expect(store.values[pluginEnabledKey('probe')], '1');
      expect(runtime.isEnabled('probe'), isTrue);
      expect(probe.starts, 1);

      // 模拟重新启动：同一份设置交给新的运行时，已启用的插件会再启动一次。
      final reloadedProbe = _ProbePlugin();
      final reloadedCatalog = PersonaCatalog(store: store);
      final reloaded = PluginRuntime(
        store: store,
        personas: reloadedCatalog,
        plugins: [reloadedProbe, PersonaPlugin(reloadedCatalog)],
      );
      await reloaded.load();
      expect(reloaded.isEnabled('probe'), isTrue);
      expect(reloadedProbe.starts, 1);

      await reloaded.setEnabled('probe', false);
      expect(store.values[pluginEnabledKey('probe')], '0');
      expect(reloaded.isEnabled('probe'), isFalse);
    });

    test('启动失败时抛出明确失败类型，启停状态不写入', () async {
      final store = MemoryPluginMetadataStore();
      final catalog = PersonaCatalog(store: store);
      final runtime = PluginRuntime(
        store: store,
        personas: catalog,
        plugins: [_BrokenPlugin(), PersonaPlugin(catalog)],
      );
      await expectLater(
        runtime.load(),
        completion(isNull),
        reason: '启动失败只记录，不打断应用启动',
      );
      expect(runtime.isEnabled('broken'), isTrue);
      expect(store.values[pluginEnabledKey('broken')], isNull);

      await expectLater(
        runtime.setEnabled('broken', true),
        throwsA(isA<PluginStartException>()),
      );
      expect(store.values[pluginEnabledKey('broken')], isNull);
    });
  });

  group('权限门面', () {
    test('假插件越权调用四条路径都被拒绝，且没有触达能力实现', () async {
      final store = MemoryPluginMetadataStore();
      final catalog = PersonaCatalog(store: store);
      final probe = _ProbePlugin();
      final runtime = PluginRuntime(
        store: store,
        personas: catalog,
        plugins: [probe, PersonaPlugin(catalog)],
      );
      await runtime.load();

      expect(probe.failures, hasLength(4));
      expect(
        probe.failures.map(
          (error) => (error as PluginPermissionDenied).permission,
        ),
        PluginPermission.values,
      );
      for (final error in probe.failures) {
        expect(error, isA<PluginPermissionDenied>());
        expect(error.toString(), contains('没有声明'));
      }

      // 门面本身也先核对权限：即使接了真实能力，未声明时一次都不会被调用。
      final network = _CountingNetwork();
      final reads = _CountingReads();
      final drafts = _CountingDrafts();
      final models = _CountingModel();
      final access = PluginAccess(
        manifest: _capabilityManifest(),
        network: network,
        dataRead: reads,
        draftSubmit: drafts,
        modelCall: models,
      );
      await expectLater(
        access.network.fetch('https://api.example.com/x'),
        throwsA(isA<PluginPermissionDenied>()),
      );
      await expectLater(
        access.readData.read(scope: 'timetable'),
        throwsA(isA<PluginPermissionDenied>()),
      );
      await expectLater(
        access.submitDraft.submit(writeType: 'timetable', draft: const {}),
        throwsA(isA<PluginPermissionDenied>()),
      );
      await expectLater(
        access.callModel.complete('问题'),
        throwsA(isA<PluginPermissionDenied>()),
      );
      expect(network.calls, 0, reason: '拒绝发生在请求之前');
      expect(reads.calls, 0);
      expect(drafts.calls, 0, reason: '拒绝发生在写入之前');
      expect(models.calls, 0);
    });

    test('声明了权限但域名、范围与写入类型不在清单里时逐项拒绝', () async {
      final access = PluginAccess(
        manifest: _capabilityManifest(
          permissions: const PluginPermissions(
            networkDomains: ['example.com'],
            readDataScopes: ['timetable'],
            writeTypes: ['timetable'],
            callModel: true,
          ),
        ),
        network: _CountingNetwork(),
        dataRead: _CountingReads(),
        draftSubmit: _CountingDrafts(),
        modelCall: _CountingModel(),
      );

      // 清单放行 example.com 与它的子域名，其他域名拒绝。
      await expectLater(
        access.network.fetch('https://api.example.com/x'),
        completion(isNull),
      );
      await expectLater(
        access.network.fetch('https://evil.test/x'),
        throwsA(
          isA<PluginPermissionDenied>().having(
            (error) => error.detail,
            'detail',
            contains('evil.test'),
          ),
        ),
      );
      await expectLater(
        access.readData.read(scope: 'materials'),
        throwsA(isA<PluginPermissionDenied>()),
      );
      await expectLater(
        access.submitDraft.submit(writeType: 'schedule', draft: const {}),
        throwsA(isA<PluginPermissionDenied>()),
      );
      // 已声明且参数合格的调用交给对应实现，本期没有真实实现也不静默降级。
      await expectLater(
        access.readData.read(scope: 'timetable'),
        completion(isNull),
      );
    });
  });

  group('人格段落', () {
    test('启用人格且插件启用时给出提示词段落，停用或换成人格为空时消失', () async {
      final store = MemoryPluginMetadataStore();
      final catalog = PersonaCatalog(store: store);
      final runtime = PluginRuntime(
        store: store,
        personas: catalog,
        plugins: [PersonaPlugin(catalog)],
      );
      await runtime.load();

      expect(runtime.activePersonaPrompt, isNull, reason: '默认没有启用人格');

      await runtime.setActivePersona('calm-teacher');
      final prompt = runtime.activePersonaPrompt;
      expect(prompt, isNotNull);
      expect(prompt!.name, '温和讲题');
      expect(prompt.text, contains('耐心'));
      expect(store.values[personaActiveKey], 'calm-teacher');

      await runtime.setEnabled('persona', false);
      expect(runtime.activePersonaPrompt, isNull);
      expect(store.values[pluginEnabledKey('persona')], '0');

      await runtime.setEnabled('persona', true);
      expect(runtime.activePersonaPrompt, isNotNull);

      await runtime.setActivePersona(null);
      expect(runtime.activePersonaPrompt, isNull);
      expect(store.values[personaActiveKey], isEmpty);
    });

    test('切换人格时拒绝未知标识', () async {
      final store = MemoryPluginMetadataStore();
      final catalog = PersonaCatalog(store: store);
      final runtime = PluginRuntime(
        store: store,
        personas: catalog,
        plugins: [PersonaPlugin(catalog)],
      );
      await runtime.load();

      await expectLater(
        runtime.setActivePersona('unknown'),
        throwsA(isA<PersonaNotFound>()),
      );
    });
  });
}
