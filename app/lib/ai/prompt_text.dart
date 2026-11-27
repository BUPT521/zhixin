/// 提示词文本的解析与取用入口。
///
/// 文件读取在 `platform/prompt_assets.dart`；本文件保持纯 Dart，供 AI 层按
/// 段落取文本、替换占位符。文本按 `## 键名` 分段，占位符写成 `{{名字}}`。
class PromptText {
  PromptText._(this._sections);

  static PromptText? _instance;

  /// 已经加载的文本；没有加载时说明启动或测试装配漏了一步。
  static PromptText get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('提示词还没有加载：先执行 PromptAssets.load()');
    }
    return value;
  }

  /// 装入已经解析好的段落；重复调用会用新内容替换。
  static void install(Map<String, String> sections) {
    _instance = PromptText._(Map.unmodifiable(sections));
  }

  final Map<String, String> _sections;

  /// 全部段落键；评测与资源检查用它确认文本没有缺段。
  Iterable<String> get keys => _sections.keys;

  String operator [](String key) {
    final value = _sections[key];
    if (value == null) throw StateError('提示词缺少段落：$key');
    return value;
  }

  /// 替换段落里的 `{{名字}}` 占位符；缺少替换值时直接报错，
  /// 避免把半截提示词发给模型。
  ///
  /// 单遍替换整段模板：替换值里的 `{{…}}` 原样保留，用户内容写进来的花括号
  /// 不会在后续轮次里被当成占位符再展开一次。
  String format(String key, Map<String, String> values) {
    final template = this[key];
    final pattern = RegExp(r'\{\{([a-z0-9_.]+)\}\}');
    final missing = pattern
        .allMatches(template)
        .map((match) => match.group(1)!)
        .toSet()
        .difference(values.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError('提示词段落 $key 缺少替换值：${missing.join('、')}');
    }
    return template.replaceAllMapped(
      pattern,
      (match) => values[match.group(1)!]!,
    );
  }

  /// 解析一份资源文本；段落键重复或为空时直接报错。
  static Map<String, String> parse(String raw, {required String source}) {
    final sections = <String, String>{};
    final buffer = <String>[];
    String? key;

    void flush() {
      final current = key;
      if (current == null) return;
      while (buffer.isNotEmpty && buffer.first.trim().isEmpty) {
        buffer.removeAt(0);
      }
      while (buffer.isNotEmpty && buffer.last.trim().isEmpty) {
        buffer.removeLast();
      }
      if (buffer.isEmpty) {
        throw StateError('提示词段落为空：$current（$source）');
      }
      sections[current] = buffer.join('\n');
      buffer.clear();
    }

    for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
      final match = RegExp(r'^## ([a-z0-9_.]+)\s*$').firstMatch(line);
      if (match != null) {
        flush();
        key = match.group(1);
        if (sections.containsKey(key)) {
          throw StateError('提示词段落重复：$key（$source）');
        }
        continue;
      }
      if (key != null) buffer.add(line);
    }
    flush();
    return sections;
  }
}
