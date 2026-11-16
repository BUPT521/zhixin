/// 人格清单与当前启用项：读写在 `app_meta`，不形成数据提交。
///
/// `persona.items` 保存 JSON 列表，第一次运行时写入两个内置人格；`persona.active`
/// 保存当前启用的标识，空串表示没有启用。整库备份包含 `app_meta`，恢复或清空
/// 之后重新调用 [load] 就能读到新状态。
library;

import '../runtime/plugin_metadata_store.dart';
import 'builtin_personas.dart';
import 'persona.dart';

/// 人格列表的设置键。
const personaItemsKey = 'persona.items';

/// 当前启用的人格标识；没有启用人格时是空串或不写这一项。
const personaActiveKey = 'persona.active';

/// 人格清单的运行时状态；同一时间只有一个启用项。
class PersonaCatalog {
  PersonaCatalog({required this.store});

  final PluginMetadataStore store;

  List<Persona> _items = List.of(builtinPersonas);
  String? _activeId;

  /// 当前可用的人格；没有任何配置时退回内置人格。
  List<Persona> get items => List.unmodifiable(_items);

  /// 当前启用的标识；没有启用时为 `null`。
  String? get activeId => _activeId;

  /// 当前启用的人格；没有启用或标识已经不在清单里时为空。
  Persona? get active => _find(_activeId);

  /// 从 `app_meta` 重读人格列表与启用项；恢复、清空或切换之后调用。
  Future<void> load() async {
    final rawItems = await store.read(personaItemsKey);
    if (rawItems == null || rawItems.trim().isEmpty) {
      _items = List.of(builtinPersonas);
      await store.write(personaItemsKey, encodePersonaItems(_items));
    } else {
      final parsed = decodePersonaItems(rawItems);
      _items = parsed.isEmpty ? List.of(builtinPersonas) : parsed;
    }
    final rawActive = await store.read(personaActiveKey);
    _activeId = _find(
      rawActive == null || rawActive.trim().isEmpty ? null : rawActive.trim(),
    )?.id;
  }

  /// 切换当前启用的人格；传空表示停用。
  ///
  /// 未知标识直接拒绝，不把启用项留成指向不存在人格的状态。
  Future<void> setActive(String? id) async {
    if (id != null && _find(id) == null) throw PersonaNotFound(id);
    await store.write(personaActiveKey, id ?? '');
    _activeId = id;
  }

  /// 保存一份人格；校验失败时抛出 [PersonaValidationException]。
  ///
  /// 本版界面不提供导入入口，这个方法留给 M3 的导入与测试；写入之后立刻可在
  /// 人格页看到，但不形成数据提交。
  Future<void> save(Persona persona) async {
    final error = validatePersona(persona);
    if (error != null) throw PersonaValidationException(error);
    final next = [
      for (final item in _items)
        if (item.id != persona.id) item,
      persona,
    ];
    await store.write(personaItemsKey, encodePersonaItems(next));
    _items = next;
    if (_activeId != null && _find(_activeId) == null) _activeId = null;
  }

  Persona? _find(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
