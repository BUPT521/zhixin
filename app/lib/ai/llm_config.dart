import 'dart:math' as math;

/// 单步输出的最高上限，实际请求还受模型上下文配置约束。
const int buddyMaxOutputTokens = 8192;

/// 接口风格：同一份回答协议，分别走 Chat Completions、Responses 与
/// Anthropic Messages 三种线格式。
///
/// 由用户显式选择，不按服务商域名猜：同一家服务商的不同地址可能只支持其中
/// 一种，猜错时只能看到 404 或 400。
enum LlmApi {
  chat('chat', 'Chat Completions'),
  responses('responses', 'Responses'),
  anthropic('anthropic', 'Anthropic Messages');

  const LlmApi(this.value, this.label);

  final String value;
  final String label;

  static LlmApi fromValue(String? value) {
    for (final api in values) {
      if (api.value == value) return api;
    }
    return LlmApi.chat;
  }

  /// 相对 base_url 的路径段。
  String get path => switch (this) {
    LlmApi.chat => 'chat/completions',
    LlmApi.responses => 'responses',
    LlmApi.anthropic => 'messages',
  };
}

/// 模型来源：自填 Key 直连提供方，或登录之后使用服务端代理。
///
/// 选择“知新服务”时地址与接口风格由服务端决定，key 用账号的访问令牌临时替换，
/// 不写入本机配置；令牌过期或退出登录时回答退回本地兜底（ADR-0008、ADR-0009）。
enum LlmSource {
  custom('custom', '自填 Key'),
  server('server', '知新服务');

  const LlmSource(this.value, this.label);

  final String value;
  final String label;

  static LlmSource fromValue(String? value) {
    for (final source in values) {
      if (source.value == value) return source;
    }
    return LlmSource.custom;
  }
}

/// 模型配置：key 存 Android Keystore，接口风格、地址、模型名都可改。
///
/// 默认 DeepSeek V4.1 flash 的 Chat Completions；key 只存在设备上，不进仓库、
/// 不写日志。选择知新服务时不保存访问令牌，运行时由账号服务填入。
class LlmConfig {
  const LlmConfig({
    this.api = LlmApi.chat,
    this.baseUrl = defaultBaseUrl,
    this.model = defaultModel,
    this.apiKey = '',
    this.allowImages = true,
    this.contextWindowTokens = defaultContextWindowTokens,
    this.source = LlmSource.custom,
  });

  static const String defaultBaseUrl = 'https://api.deepseek.com/v1';
  static const String defaultModel = 'deepseek-flash';
  static const int defaultContextWindowTokens = 65536;

  final LlmApi api;
  final String baseUrl;
  final String model;
  final String apiKey;

  /// 回答走自填 Key 还是登录后的服务端代理。
  final LlmSource source;

  /// 是否允许把原题图片发给模型；关闭后只能手填或纯文字讲题。
  final bool allowImages;
  final int contextWindowTokens;

  int get outputTokenLimit =>
      math.min(buddyMaxOutputTokens, math.max(1, contextWindowTokens ~/ 4));

  bool get isServer => source == LlmSource.server;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty;

  LlmConfig copyWith({
    LlmApi? api,
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? allowImages,
    int? contextWindowTokens,
    LlmSource? source,
  }) {
    return LlmConfig(
      api: api ?? this.api,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      allowImages: allowImages ?? this.allowImages,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      source: source ?? this.source,
    );
  }

  /// 换了接口地址却还带着旧地址的 Key：测试或保存前要拦住，避免把凭据发到
  /// 新地址，也避免用户以为已经验证过新配置。
  bool reusesKeyFrom(LlmConfig? previous) {
    if (previous == null) return false;
    final oldKey = previous.apiKey.trim();
    return oldKey.isNotEmpty &&
        apiKey.trim() == oldKey &&
        baseUrl.trim() != previous.baseUrl.trim();
  }

  /// 允许用户填到 `/v1`，也可以直接填完整的接口地址。
  ///
  /// 只填域名时补 `/v1`，与三家 SDK 的默认拼接一致；Anthropic 的约定是
  /// base 之后固定接 `/v1/messages`，所以带路径但没写 `/v1` 时（例如
  /// `https://api.deepseek.com/anthropic`）也要补上。
  String get endpoint {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return '';
    if (base.endsWith('/${api.path}')) return base;
    final hasPath =
        Uri.tryParse(base)?.pathSegments.any((segment) => segment.isNotEmpty) ??
        false;
    if (!hasPath) return '$base/v1/${api.path}';
    if (api == LlmApi.anthropic && !base.endsWith('/v1')) {
      return '$base/v1/${api.path}';
    }
    return '$base/${api.path}';
  }

  String get _host => Uri.tryParse(endpoint)?.host.toLowerCase() ?? '';

  /// 地址或模型名指向 DeepSeek：只有这类服务认 `thinking`，其他兼容实现收到
  /// 不认识的字段可能直接返回 400。
  bool get isDeepSeek =>
      _host.contains('deepseek') ||
      model.trim().toLowerCase().startsWith('deepseek');

  bool get isOpenAi => _host == 'api.openai.com';

  Map<String, String> toJson() => {
    'api': api.value,
    'base_url': baseUrl,
    'model': model,
    'api_key': apiKey,
    'allow_images': allowImages ? '1' : '0',
    'context_window_tokens': contextWindowTokens.toString(),
    'source': source.value,
  };

  factory LlmConfig.fromJson(Map<String, Object?> json) {
    final window = int.tryParse(
      json['context_window_tokens']?.toString() ?? '',
    );
    return LlmConfig(
      api: LlmApi.fromValue(json['api'] as String?),
      baseUrl: (json['base_url'] as String?) ?? defaultBaseUrl,
      model: (json['model'] as String?) ?? defaultModel,
      apiKey: (json['api_key'] as String?) ?? '',
      allowImages: (json['allow_images'] as String?) != '0',
      contextWindowTokens: window != null && window > 0
          ? window
          : defaultContextWindowTokens,
      source: LlmSource.fromValue(json['source'] as String?),
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
