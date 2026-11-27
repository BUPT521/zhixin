import 'package:flutter/widgets.dart';

import '../ai/llm_config.dart';

/// 模型配置表单：模型名、上下文上限与图片开关。
///
/// 页面只读 [config]、[allowImages] 与两个输入框，把服务返回的配置交给
/// [apply]；解析输入与上限校验收在 [read] 里，页面不再各写一遍。上下文上限
/// 留空表示默认值，超出范围时抛 [FormatException]，说明给用户看。
class SettingsModelForm {
  final TextEditingController model = TextEditingController();
  final TextEditingController contextWindow = TextEditingController();

  LlmConfig? _config;
  bool _allowImages = true;

  /// 当前生效的配置；为空表示用默认模型。
  LlmConfig? get config => _config;

  bool get allowImages => _allowImages;

  /// 是否已经自定义过模型名、上下文上限或图片开关。
  bool get customized => _config != null;

  void setAllowImages(bool value) => _allowImages = value;

  /// 把一份模型配置填回输入框；为空时回到默认值与空输入。
  void apply(LlmConfig? config) {
    _config = config;
    _allowImages = config?.allowImages ?? true;
    model.text = config?.model ?? LlmConfig.defaultModel;
    final window = config?.contextWindowTokens;
    contextWindow.text =
        window == null || window == LlmConfig.defaultContextWindowTokens
        ? ''
        : window.toString();
  }

  /// 按输入框里的内容拼一份配置；上限不是正整数或超过允许范围时抛
  /// [FormatException]。
  LlmConfig read() {
    final input = contextWindow.text.trim();
    final window = input.isEmpty
        ? LlmConfig.defaultContextWindowTokens
        : int.tryParse(input);
    if (window == null || window <= 0) {
      throw const FormatException('模型上下文上限须为正整数');
    }
    if (window > LlmConfig.maxContextWindowTokens) {
      throw FormatException('模型上下文上限不能超过 ${LlmConfig.maxContextWindowTokens}');
    }
    final name = model.text.trim();
    return LlmConfig(
      model: name.isEmpty ? LlmConfig.defaultModel : name,
      allowImages: _allowImages,
      contextWindowTokens: window,
    );
  }

  void dispose() {
    model.dispose();
    contextWindow.dispose();
  }
}
