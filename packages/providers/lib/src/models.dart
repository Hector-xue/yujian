import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'provider.dart';

/// 从厂商错误响应里抠出人能读的一句话：OpenAI 系是 {"error":{"message":…}}，Anthropic 是 {"error":{"message":…}} 或 {"message":…}；
/// 都不是就原样截短。
String providerErrorMessage(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final e = j['error'];
      if (e is Map && e['message'] is String) return _short(e['message'] as String);
      if (e is String) return _short(e);
      if (j['message'] is String) return _short(j['message'] as String);
      if (j['detail'] is String) return _short(j['detail'] as String);
    }
  } catch (_) {}
  return _short(body);
}

String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;

/// 列出端点上可用的模型名（GET /models）。OpenAI 兼容与 Anthropic 都是 {"data":[{"id":…}]}；
/// 有的中转不实现这个接口，抛 ProviderException 让上层提示手填。
Future<List<String>> listModels(ProviderConfig config, {http.Client? client, Duration timeout = const Duration(seconds: 15)}) async {
  final base = config.baseUrl.endsWith('/') ? config.baseUrl.substring(0, config.baseUrl.length - 1) : config.baseUrl;
  final headers = config.type == ProviderType.anthropic
      ? {'x-api-key': config.apiKey ?? '', 'anthropic-version': '2023-06-01'}
      : {if (config.apiKey != null && config.apiKey!.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}'};
  final c = client ?? http.Client();
  http.Response resp;
  try {
    resp = await c.get(Uri.parse('$base/models'), headers: headers).timeout(timeout);
  } on TimeoutException {
    throw ProviderException('timeout after ${timeout.inSeconds}s', retryable: true);
  } on http.ClientException catch (e) {
    throw ProviderException('network: ${e.message}', retryable: true);
  } finally {
    if (client == null) c.close();
  }
  final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw ProviderException(providerErrorMessage(text), status: resp.statusCode, retryable: resp.statusCode >= 500);
  }
  Object? j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    throw ProviderException('non-JSON response: ${_short(text)}');
  }
  final data = j is Map ? (j['data'] ?? j['models']) : j;
  if (data is! List) throw ProviderException('这个端点不提供模型列表');
  final ids = <String>{};
  for (final m in data) {
    if (m is Map) {
      final id = m['id'] ?? m['name'] ?? m['model'];
      if (id is String && id.isNotEmpty) ids.add(id);
    } else if (m is String) {
      ids.add(m);
    }
  }
  return ids.toList()..sort();
}
