import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'provider.dart';

/// 云端语音转写：OpenAI 兼容的 `POST /audio/transcriptions`（whisper、SenseVoice、Paraformer 等都走这个形状）。
/// 手机没有系统语音识别（国产 ROM 常见）时的兜底；Anthropic 没这个接口。
Future<String> transcribeAudio(ProviderConfig config, Uint8List bytes, {required String filename, required String mime, required String model, String language = 'zh', http.Client? client, Duration timeout = const Duration(seconds: 60)}) async {
  if (config.type == ProviderType.anthropic) throw ProviderException('Anthropic 没有语音转写接口，换一个 OpenAI 兼容端点');
  final base = config.baseUrl.endsWith('/') ? config.baseUrl.substring(0, config.baseUrl.length - 1) : config.baseUrl;
  final req = http.MultipartRequest('POST', Uri.parse('$base/audio/transcriptions'))
    ..fields['model'] = model
    ..fields['language'] = language
    ..fields['response_format'] = 'json'
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: _mediaType(mime)));
  if (config.apiKey != null && config.apiKey!.isNotEmpty) req.headers['Authorization'] = 'Bearer ${config.apiKey}';
  final c = client ?? http.Client();
  http.Response resp;
  try {
    resp = await http.Response.fromStream(await c.send(req).timeout(timeout)).timeout(timeout);
  } on TimeoutException {
    throw ProviderException('timeout after ${timeout.inSeconds}s', retryable: true);
  } on http.ClientException catch (e) {
    throw ProviderException('network: ${e.message}', retryable: true);
  } finally {
    if (client == null) c.close();
  }
  final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw ProviderException(providerErrorMessage(text), status: resp.statusCode, retryable: resp.statusCode >= 500 || resp.statusCode == 429);
  }
  try {
    final j = jsonDecode(text);
    if (j is Map && j['text'] is String) return (j['text'] as String).trim();
  } catch (_) {
    return text.trim(); // response_format=text 的服务
  }
  throw ProviderException('转写响应里没有 text：${text.length > 200 ? text.substring(0, 200) : text}');
}

http.MediaType? _mediaType(String mime) {
  final parts = mime.split('/');
  return parts.length == 2 ? http.MediaType(parts[0], parts[1]) : null;
}
