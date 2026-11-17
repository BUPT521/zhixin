import 'package:flutter/services.dart';

import '../ai/prompt_text.dart';

/// 提示词资源的读取入口。
///
/// 文件读取属于平台适配，放在这里；AI 层只通过 [PromptText] 取段落。应用在
/// 启动时调用一次，测试在 `test/flutter_test_config.dart` 里调用一次。
class PromptAssets {
  static const String systemAsset = 'assets/prompts/buddy_system.md';
  static const String requestAsset = 'assets/prompts/buddy_prompts.md';
  static const String toolsAsset = 'assets/prompts/buddy_tools.md';

  static Future<void> load({AssetBundle? bundle}) async {
    final source = bundle ?? rootBundle;
    final sections = <String, String>{};
    for (final path in const [systemAsset, requestAsset, toolsAsset]) {
      final raw = await source.loadString(path);
      for (final entry in PromptText.parse(raw, source: path).entries) {
        if (sections.containsKey(entry.key)) {
          throw StateError('提示词段落重复：${entry.key}');
        }
        sections[entry.key] = entry.value;
      }
    }
    PromptText.install(sections);
  }
}
