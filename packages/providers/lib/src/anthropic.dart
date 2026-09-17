import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'provider.dart';

/// Anthropic Messages API（/v1/messages）。JSON 模式靠提示词约束（Anthropic 没有 response_format）。
class AnthropicProvider implements ChatProvider {
  final ProviderConfig config;
  final http.Client _client;
  AnthropicProvider(this.config, {http.Client? client}) : _client = client ?? http.Client();

  @override
  String get name => config.name;
  @override
  String get model => config.model;

  Uri get _endpoint {
    final base = config.baseUrl.endsWith('/') ? config.baseUrl.substring(0, config.baseUrl.length - 1) : config.baseUrl;
    return Uri.parse('$base/messages');
  }

  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) =>
      _post(system: system, content: user, jsonMode: jsonMode, temperature: temperature, timeout: timeout ?? config.timeout, model: config.model);

  @override
  Future<ChatResult> completeWithImages({required String system, required String user, required List<ImageInput> images, bool jsonMode = false, Duration? timeout}) =>
      _post(
        system: system,
        content: [
          for (final im in images) {'type': 'image', 'source': {'type': 'base64', 'media_type': im.mime, 'data': base64Encode(im.bytes)}},
          {'type': 'text', 'text': user},
        ],
        jsonMode: jsonMode,
        timeout: timeout ?? config.timeout,
        model: config.visionModel ?? config.model,
      );

  Future<ChatResult> _post({required String system, required Object content, required bool jsonMode, double? temperature, required Duration timeout, required String model}) async {
    final sw = Stopwatch()..start();
    final body = {
      'model': model,
      'max_tokens': config.maxTokens ?? 2048,
      'system': jsonMode ? '$system\n\n只输出一个 JSON 对象，不要任何其他文字。' : system,
      'messages': [
        {'role': 'user', 'content': content},
      ],
      'temperature': temperature ?? config.temperature,
      ...config.extraBody,
    };
    http.Response resp;
    try {
      resp = await _client
          .post(_endpoint, headers: {'Content-Type': 'application/json', 'x-api-key': config.apiKey ?? '', 'anthropic-version': '2023-06-01'}, body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw ProviderException('timeout after ${timeout.inSeconds}s', retryable: true);
    } on http.ClientException catch (e) {
      throw ProviderException('network: ${e.message}', retryable: true);
    }
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ProviderException(providerErrorMessage(text), status: resp.statusCode, retryable: resp.statusCode >= 500 || resp.statusCode == 429);
    }
    final json = jsonDecode(text) as Map<String, Object?>;
    final parts = (json['content'] as List? ?? const []).cast<Map>();
    final out = parts.where((p) => p['type'] == 'text').map((p) => p['text'] as String).join();
    if (out.isEmpty) throw ProviderException('empty content');
    final u = json['usage'] as Map?;
    return ChatResult(
      text: out,
      model: (json['model'] as String?) ?? model,
      usage: u == null ? null : ChatUsage((u['input_tokens'] as num?)?.toInt() ?? 0, (u['output_tokens'] as num?)?.toInt() ?? 0),
      latency: sw.elapsed,
    );
  }
}

/// 按配置类型造 Provider。Gemini 用它的 OpenAI 兼容端点（…/v1beta/openai）。
ChatProvider providerFor(ProviderConfig cfg, {http.Client? client}) => switch (cfg.type) {
      ProviderType.anthropic => AnthropicProvider(cfg, client: client),
      _ => throw UnimplementedError('use OpenAICompatProvider for ${cfg.type}'),
    };
