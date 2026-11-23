import 'dart:math' as math;

/// 单步输出的最高上限，实际请求还受模型上下文配置约束。这个数字与服务端
/// `llmproxy` 的 `maxOutputTokens` 相同，一端改动要同时改另一端，否则服务端
/// 会按 `max_output_tokens` 超出范围回 400（ADR-0055）。
const int buddyMaxOutputTokens = 32768;

/// 模型配置：只记用户可选的模型名、上下文上限与图片开关。
///
/// 客户端只用“知新服务”：接口地址在运行时由账号服务按 `<服务地址>` 拼出，对话
/// 走 `/v1/llm/responses`，嵌入走 `/v1/llm/embeddings`（ADR-0052）；访问令牌代替
/// key 临时填进请求，两者都不写进本机配置。令牌过期、退出登录或没有登录时回答
/// 退回本地兜底（ADR-0008、ADR-0009）。
class LlmConfig {
  const LlmConfig({
    this.model = defaultModel,
    this.allowImages = true,
    this.contextWindowTokens = defaultContextWindowTokens,
    this.apiKey = '',
    this.endpoint = '',
  });

  /// 默认模型名与服务端管理后台的对外模型名一致；后台改名时两边一起改。
  static const String defaultModel = 'zhixin-chat';
  static const int defaultContextWindowTokens = 65536;

  /// 上下文上限可以填的最大值，与单步输出上限的实际取值保持一致。
  static const int maxContextWindowTokens = buddyMaxOutputTokens;

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
