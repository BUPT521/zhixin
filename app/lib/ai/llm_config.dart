import 'dart:math' as math;

/// 单步输出的最高上限，实际请求还受模型上下文配置约束。
const int buddyMaxOutputTokens = 8192;

/// 模型配置：只记用户可选的模型名、上下文上限与图片开关。
///
/// 客户端只用“知新服务”：地址按 `<服务地址>/v1/llm` 在运行时由账号服务拼出，
/// 访问令牌代替 key 临时填进请求，两者都不写进本机配置；接口固定走 Chat
/// Completions。令牌过期、退出登录或没有登录时回答退回本地兜底
/// （ADR-0008、ADR-0009）。
class LlmConfig {
  const LlmConfig({
    this.model = defaultModel,
    this.allowImages = true,
    this.contextWindowTokens = defaultContextWindowTokens,
    this.apiKey = '',
    this.endpoint = '',
  });

  static const String defaultModel = 'deepseek-flash';
  static const int defaultContextWindowTokens = 65536;

  /// 模型名；留空即视为没有配置。
  final String model;

  /// 是否允许把原题图片发给模型；关闭后只能手填或纯文字讲题。
  final bool allowImages;
  final int contextWindowTokens;

  /// 请求用的访问令牌与完整接口地址，只由账户服务在发请求前补上，随配置
  /// 保存的那一份始终为空。
  final String apiKey;
  final String endpoint;

  int get outputTokenLimit =>
      math.min(buddyMaxOutputTokens, math.max(1, contextWindowTokens ~/ 4));

  /// 填了模型名才算配置好；能不能真正发出请求还要看当前账号是否登录。
  bool get isConfigured => model.trim().isNotEmpty;

  /// 按模型名推测背后的提供方是 DeepSeek：只有这类服务认 `thinking`，其他
  /// 提供方收到不认识的字段可能直接返回 400，所以请求里按模型名决定是否发送。
  bool get reasoningDisabled =>
      model.trim().toLowerCase().startsWith('deepseek');

  LlmConfig copyWith({
    String? model,
    bool? allowImages,
    int? contextWindowTokens,
    String? apiKey,
    String? endpoint,
  }) {
    return LlmConfig(
      model: model ?? this.model,
      allowImages: allowImages ?? this.allowImages,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      apiKey: apiKey ?? this.apiKey,
      endpoint: endpoint ?? this.endpoint,
    );
  }

  /// 只保存用户可选的几项；令牌与地址随请求走，不进 Keystore。
  Map<String, String> toJson() => {
    'model': model,
    'allow_images': allowImages ? '1' : '0',
    'context_window_tokens': contextWindowTokens.toString(),
  };

  factory LlmConfig.fromJson(Map<String, Object?> json) {
    final window = int.tryParse(
      json['context_window_tokens']?.toString() ?? '',
    );
    return LlmConfig(
      model: (json['model'] as String?) ?? defaultModel,
      allowImages: (json['allow_images'] as String?) != '0',
      contextWindowTokens: window != null && window > 0
          ? window
          : defaultContextWindowTokens,
    );
  }
}

/// 本次操作已读取的配置，允许明确区分“已读取但未配置”和“尚未读取”。
class LlmConfigSnapshot {
  const LlmConfigSnapshot(this.value);

  final LlmConfig? value;
}

/// key 的落点；测试里换成内存实现，不碰平台通道。
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 读 Keystore 本身失败（不是没配置）。上层可以沿用上一次读到的配置，
/// 不要把一次读取失败当成“没有配置”。
class LlmConfigReadFailure implements Exception {
  const LlmConfigReadFailure(this.cause);

  final Object cause;

  @override
  String toString() => '读取模型配置失败：$cause';
}
