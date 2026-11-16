import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/plugin_metadata_store.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/plugins/persona/builtin_personas.dart';
import 'package:zhixin/plugins/persona/persona.dart';
import 'package:zhixin/plugins/persona/persona_catalog.dart';
import 'package:zhixin/plugins/persona/persona_plugin.dart';
import 'package:zhixin/plugins/runtime/plugin_runtime.dart';

import '../support/plugin_memory_store.dart';
import '../support/test_db.dart';

void main() {
  test('人格文本按码位计数，超过 800 字时说明超出的字数', () {
    expect(validatePersonaText('字' * 800), isNull);
    expect(validatePersonaText('字' * 801), contains('超出上限 1 字'));
    expect(validatePersonaText('字' * 812), contains('812 字'));
    expect(validatePersonaText(''), '人格设定不能为空');
    // 表情按码位计数，不会因为代理对被算成两个字。
    expect(validatePersonaText('😀' * 800), isNull);
    expect(validatePersonaText('😀' * 801), contains('超出上限 1 字'));
  });

  test('人格 JSON 往返，损坏的条目跳过', () {
    const persona = Persona(
      id: 'custom',
      name: '自定义',
      description: '说明',
      author: '作者',
      text: '设定文本',
    );
    final decoded = decodePersonaItems(encodePersonaItems([persona]));
    expect(decoded, hasLength(1));
    expect(decoded.single.name, '自定义');
    expect(decoded.single.text, '设定文本');
    expect(decodePersonaItems('不是 JSON'), isEmpty);
    expect(decodePersonaItems('{"id": 1}'), isEmpty);
    expect(decodePersonaItems('[{"id":"a"}]'), isEmpty, reason: '缺字段的条目跳过');
  });

  test('两个内置人格不超过上限，也不含改变判分、引用与写入的指令', () {
    expect(builtinPersonas, hasLength(2));
    expect(builtinPersonas.map((persona) => persona.id).toSet(), hasLength(2));
    for (final persona in builtinPersonas) {
      expect(validatePersona(persona), isNull);
      expect(persona.text.runes.length, lessThanOrEqualTo(800));
      for (final forbidden in ['判分', '引用', '写入', '工具', '提交', '不要核对']) {
        expect(
          persona.text,
          isNot(contains(forbidden)),
          reason: '${persona.id} 不能写改变规则的指令',
        );
      }
    }
  });

  test('人格清单写入 app_meta，切换启用项之后重新读取仍然生效', () async {
    final store = MemoryPluginMetadataStore();
    final catalog = PersonaCatalog(store: store);
    await catalog.load();
    expect(catalog.items.map((persona) => persona.id), [
      'calm-teacher',
      'brief-coach',
    ]);
    expect(store.values[personaItemsKey], isNotNull, reason: '第一次运行时写入内置人格');
    expect(catalog.activeId, isNull);

    await catalog.setActive('brief-coach');
    expect(store.values[personaActiveKey], 'brief-coach');

    final reloaded = PersonaCatalog(store: store);
    await reloaded.load();
    expect(reloaded.activeId, 'brief-coach');
    expect(reloaded.active!.name, '简短直接');

    await expectLater(
      reloaded.setActive('unknown'),
      throwsA(isA<PersonaNotFound>()),
    );
    await reloaded.setActive(null);
    expect(reloaded.active, isNull);
    expect(store.values[personaActiveKey], isEmpty);
  });

  test('保存超长人格被拒绝，合法的保存可以往返', () async {
    final store = MemoryPluginMetadataStore();
    final catalog = PersonaCatalog(store: store);
    await catalog.load();

    await expectLater(
      catalog.save(
        Persona(
          id: 'long',
          name: '长',
          description: '说明',
          author: '作者',
          text: '字' * 812,
        ),
      ),
      throwsA(
        isA<PersonaValidationException>().having(
          (error) => error.message,
          'message',
          allOf(contains('812 字'), contains('超出上限 12 字')),
        ),
      ),
    );
    expect(catalog.items.map((persona) => persona.id), isNot(contains('long')));

    const custom = Persona(
      id: 'custom',
      name: '自定义',
      description: '说明',
      author: '作者',
      text: '按这个语气说话。',
    );
    await catalog.save(custom);
    final reloaded = PersonaCatalog(store: store);
    await reloaded.load();
    expect(reloaded.items.map((persona) => persona.id), contains('custom'));
    expect(reloaded.items.last.name, '自定义');
  });

  test('app_meta 往返：恢复或清空之后重读，运行时的当前人格立即变化', () async {
    final raw = await openTestDb();
    addTearDown(raw.close);
    final settings = SettingsRepository(raw);
    final clock = DateTime(2026, 11, 16, 10);
    final store = SettingsPluginMetadataStore(settings, () => clock);
    final catalog = PersonaCatalog(store: store);
    final runtime = PluginRuntime(
      store: store,
      personas: catalog,
      plugins: [PersonaPlugin(catalog)],
    );

    await runtime.load();
    expect(await settings.metadata(personaItemsKey), isNotNull);
    expect(await settings.metadata(personaActiveKey), isNull);

    await runtime.setActivePersona('calm-teacher');
    expect(await settings.metadata(personaActiveKey), 'calm-teacher');
    expect(runtime.activePersonaPrompt!.name, '温和讲题');

    // 模拟整库恢复：app_meta 换成另一份内容，再按恢复后的流程重读。
    await settings.setMetadata(
      personaItemsKey,
      jsonEncode([
        {
          'id': 'restored',
          'name': '恢复后的人格',
          'description': '说明',
          'author': '作者',
          'text': '恢复之后用这个语气。',
        },
      ]),
      DateTime(2026, 11, 16, 11),
    );
    await settings.setMetadata(
      personaActiveKey,
      'restored',
      DateTime(2026, 11, 16, 11),
    );

    await runtime.reload();
    expect(runtime.activePersonaPrompt, isNotNull);
    expect(runtime.activePersonaPrompt!.name, '恢复后的人格');
    expect(runtime.activePersonaPrompt!.text, '恢复之后用这个语气。');

    // 提示词入口每轮重读设置：不经过页面或 reload，恢复后下一轮回答就用新人格。
    await settings.setMetadata(
      personaItemsKey,
      jsonEncode([
        {
          'id': 'restored',
          'name': '恢复后的人格',
          'description': '说明',
          'author': '作者',
          'text': '恢复之后用这个语气。',
        },
        {
          'id': 'calm-teacher',
          'name': '温和讲题',
          'description': '说明',
          'author': '知新内置',
          'text': '语气平和。',
        },
      ]),
      DateTime(2026, 11, 16, 12),
    );
    await settings.setMetadata(
      personaActiveKey,
      'calm-teacher',
      DateTime(2026, 11, 16, 12),
    );
    final promptPersona = await runtime.loadActivePersonaForPrompt();
    expect(promptPersona!.name, '温和讲题');

    // 清空之后 app_meta 没有这两项，重新读取退回内置人格且没有启用项。
    await settings.setMetadata(personaItemsKey, '', DateTime(2026, 11, 16, 12));
    await settings.setMetadata(
      personaActiveKey,
      '',
      DateTime(2026, 11, 16, 12),
    );
    await runtime.reload();
    expect(runtime.personas.items.map((persona) => persona.id), [
      'calm-teacher',
      'brief-coach',
    ]);
    expect(runtime.activePersonaPrompt, isNull);
  });
}
