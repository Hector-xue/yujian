enum ProviderType { openaiCompat, anthropic, ollama, gemini }

/// Provider 配置（§9.2）。api_key 由上层从安全存储取出后再构造，这里不负责持久化。
class ProviderConfig {
  final String name;
  final ProviderType type;
  final String baseUrl;
  final String? apiKey;
  final String model;
  final double temperature;
  final int? maxTokens;
  final Duration timeout;
  /// 原样并入请求体的厂商特有字段（如 OpenRouter 的 reasoning 开关）。
  final Map<String, Object?> extraBody;

  const ProviderConfig({
    required this.name,
    required this.type,
    required this.baseUrl,
    this.apiKey,
    required this.model,
    this.temperature = 0.2,
    this.maxTokens,
    this.timeout = const Duration(seconds: 60),
    this.extraBody = const {},
  });

  /// 从环境变量构造（开发与语料回归用）：YUJIAN_LLM_BASE_URL / YUJIAN_LLM_API_KEY / YUJIAN_LLM_MODEL。
  static ProviderConfig? fromEnvironment(Map<String, String> env) {
    final base = env['YUJIAN_LLM_BASE_URL'];
    final model = env['YUJIAN_LLM_MODEL'];
    if (base == null || base.isEmpty || model == null || model.isEmpty) return null;
    // OpenRouter 上的推理模型默认会先"思考"，解析这种小任务只会拖慢十几秒；关掉。
    final extra = <String, Object?>{
      if (base.contains('openrouter.ai')) 'reasoning': {'enabled': false},
    };
    return ProviderConfig(
      name: 'env',
      type: ProviderType.openaiCompat,
      baseUrl: base,
      apiKey: env['YUJIAN_LLM_API_KEY'],
      model: model,
      extraBody: extra,
    );
  }
}
