import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'provider.dart';

/// OpenAI-compatible `/chat/completions`。覆盖 OpenAI、DeepSeek、各类中转、Ollama(/v1)、LM Studio、vLLM。
/// 用 package:http，原生与 Web 都能跑。
class OpenAICompatProvider implements ChatProvider {
  final ProviderConfig config;
  final http.Client _client;

  OpenAICompatProvider(this.config, {http.Client? client}) : _client = client ?? http.Client();

  @override
  String get name => config.name;
  @override
  String get model => config.model;

  Uri get _endpoint {
    final base = config.baseUrl.endsWith('/') ? config.baseUrl.substring(0, config.baseUrl.length - 1) : config.baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  @override
  Future<ChatResult> complete({
    required String system,
    required String user,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
  }) async {
    final body = <String, Object?>{
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'temperature': temperature ?? config.temperature,
      if (config.maxTokens != null) 'max_tokens': config.maxTokens,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      'stream': false,
      ...config.extraBody,
    };
    try {
      return await _post(body, timeout ?? config.timeout);
    } on ProviderException catch (e) {
      // 有些兼容服务不认 response_format；400 时去掉再试一次，让 JSON 靠提示词约束。
      if (jsonMode && e.status == 400) {
        body.remove('response_format');
        return _post(body, timeout ?? config.timeout);
      }
      rethrow;
    }
  }

  @override
  Future<ChatResult> completeWithImages({
    required String system,
    required String user,
    required List<ImageInput> images,
    bool jsonMode = false,
    Duration? timeout,
  }) async {
    final body = <String, Object?>{
      'model': config.visionModel ?? config.model,
      'messages': [
        {'role': 'system', 'content': system},
        {
          'role': 'user',
          'content': [
            for (final im in images) {'type': 'image_url', 'image_url': {'url': 'data:${im.mime};base64,${base64Encode(im.bytes)}'}},
            {'type': 'text', 'text': user},
          ],
        },
      ],
      'temperature': config.temperature,
      if (config.maxTokens != null) 'max_tokens': config.maxTokens,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      'stream': false,
      ...config.extraBody,
    };
    try {
      return await _post(body, timeout ?? config.timeout);
    } on ProviderException catch (e) {
      if (jsonMode && e.status == 400) {
        body.remove('response_format');
        return _post(body, timeout ?? config.timeout);
      }
      rethrow;
    }
  }

  Future<ChatResult> _post(Map<String, Object?> body, Duration timeout) async {
    final sw = Stopwatch()..start();
    http.Response resp;
    try {
      resp = await _client
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              if (config.apiKey != null && config.apiKey!.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw ProviderException('timeout after ${timeout.inSeconds}s', retryable: true);
    } on http.ClientException catch (e) {
      throw ProviderException('network: ${e.message}', retryable: true);
    } catch (e) {
      throw ProviderException('transport: $e', retryable: true);
    }
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ProviderException(providerErrorMessage(text), status: resp.statusCode, retryable: resp.statusCode >= 500 || resp.statusCode == 429);
    }
    final Map<String, Object?> json;
    try {
      json = jsonDecode(text) as Map<String, Object?>;
    } catch (_) {
      throw ProviderException('non-JSON response: ${_short(text)}');
    }
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw ProviderException('no choices: ${_short(text)}');
    }
    final msg = (choices.first as Map)['message'] as Map?;
    final content = msg?['content'];
    if (content is! String) throw ProviderException('empty content: ${_short(text)}');
    final u = json['usage'] as Map?;
    return ChatResult(
      text: content,
      model: (json['model'] as String?) ?? config.model,
      usage: u == null ? null : ChatUsage((u['prompt_tokens'] as num?)?.toInt() ?? 0, (u['completion_tokens'] as num?)?.toInt() ?? 0),
      latency: sw.elapsed,
    );
  }

  static String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
