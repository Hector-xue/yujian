import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'provider.dart';

/// 豆包语音合成（火山引擎，seed-tts-2.0）：短剧配音同款。
/// 新控制台只要一个 API Key（X-Api-Key）；老账号是 App ID + Access Key。音色是 voice_type，语气用自然语言（context_texts）。
class DoubaoTtsConfig {
  final String? apiKey;
  final String? appId;
  final String? accessKey;
  final String voice;
  final String resourceId;
  final String baseUrl; // 测试时换成假服务器
  const DoubaoTtsConfig({this.apiKey, this.appId, this.accessKey, required this.voice, this.resourceId = 'seed-tts-2.0', this.baseUrl = 'https://openspeech.bytedance.com'});

  bool get configured => voice.isNotEmpty && ((apiKey ?? '').isNotEmpty || ((appId ?? '').isNotEmpty && (accessKey ?? '').isNotEmpty));
}

/// 单向流式 HTTP：响应是一行一个 JSON（或 SSE 的 `data: {...}`），每行 `data` 是一段 base64 音频，拼起来就是整段 mp3。
Future<Uint8List> doubaoSynthesize(DoubaoTtsConfig c, String text, {String? style, double speed = 1.0, http.Client? client, Duration timeout = const Duration(seconds: 30)}) async {
  if (!c.configured) throw ProviderException('豆包语音还没配好：要 API Key（或 App ID + Access Key）和音色');
  if (text.trim().isEmpty) return Uint8List(0);
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'X-Api-Resource-Id': c.resourceId,
    'X-Api-Request-Id': _uuid(),
    if ((c.apiKey ?? '').isNotEmpty) 'X-Api-Key': c.apiKey! else ...{'X-Api-App-Id': c.appId!, 'X-Api-Access-Key': c.accessKey!},
  };
  final additions = <String, Object?>{
    if (style != null && style.trim().isNotEmpty) 'context_texts': [style.trim()],
  };
  final body = {
    'user': {'uid': 'yujian'},
    'req_params': {
      'text': text,
      'speaker': c.voice,
      'audio_params': {'format': 'mp3', 'sample_rate': 24000, if (speed != 1.0) 'speech_rate': ((speed - 1) * 50).round().clamp(-50, 100)},
      if (additions.isNotEmpty) 'additions': jsonEncode(additions), // 文档要求：序列化后的字符串，不是对象
    },
  };
  final cl = client ?? http.Client();
  http.Response resp;
  try {
    resp = await cl.post(Uri.parse('${_trim(c.baseUrl)}/api/v3/tts/unidirectional'), headers: headers, body: jsonEncode(body)).timeout(timeout);
  } on TimeoutException {
    throw ProviderException('timeout after ${timeout.inSeconds}s', retryable: true);
  } on http.ClientException catch (e) {
    throw ProviderException('network: ${e.message}', retryable: true);
  } finally {
    if (client == null) cl.close();
  }
  final text0 = utf8.decode(resp.bodyBytes, allowMalformed: true);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw ProviderException(_doubaoError(text0, resp.statusCode), status: resp.statusCode, retryable: resp.statusCode >= 500 || resp.statusCode == 429);
  }
  final chunks = <List<int>>[];
  String? err;
  for (var line in const LineSplitter().convert(text0)) {
    line = line.trim();
    if (line.startsWith('data:')) line = line.substring(5).trim();
    if (line.isEmpty || !line.startsWith('{')) continue;
    Object? j;
    try {
      j = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (j is! Map) continue;
    final code = (j['code'] as num?)?.toInt() ?? 0;
    // 2000xxxx 都是正常（数据 / 结束）；别的是错
    if (code != 0 && (code < 20000000 || code >= 30000000)) {
      err ??= '${j['message'] ?? 'code $code'}（$code）';
      continue;
    }
    final d = j['data'];
    if (d is String && d.isNotEmpty) chunks.add(base64Decode(d));
  }
  if (chunks.isEmpty) throw ProviderException(err ?? '豆包没返回音频：${text0.length > 200 ? text0.substring(0, 200) : text0}');
  final out = BytesBuilder(copy: false);
  for (final ch in chunks) {
    out.add(ch);
  }
  return out.takeBytes();
}

String _doubaoError(String body, int status) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final m = j['message'] ?? j['error'];
      if (m is String && m.isNotEmpty) return status == 401 || status == 403 ? '鉴权失败：$m（检查 API Key / 是否开通了语音合成大模型）' : m;
    }
  } catch (_) {}
  return switch (status) {
    401 || 403 => '鉴权失败（HTTP $status）：检查 API Key，以及控制台里是否开通了「语音合成大模型」',
    _ => 'HTTP $status：${body.length > 160 ? body.substring(0, 160) : body}',
  };
}

/// MiniMax 语音（speech-02-hd 等）：HTTP `/v1/t2a_v2`，Bearer key；音频是 hex 字符串。情绪是枚举。
class MiniMaxTtsConfig {
  final String apiKey;
  final String? groupId; // 老账号才需要
  final String model;
  final String voice;
  final String baseUrl;
  const MiniMaxTtsConfig({required this.apiKey, this.groupId, this.model = 'speech-02-hd', required this.voice, this.baseUrl = 'https://api.minimaxi.com'});
  bool get configured => apiKey.isNotEmpty && voice.isNotEmpty && model.isNotEmpty;
}

const minimaxEmotions = ['happy', 'sad', 'angry', 'fearful', 'disgusted', 'surprised', 'calm', 'fluent', 'whisper'];

/// 把用户写的语气（"温柔、开心一点"）折成 MiniMax 认的枚举；认不出给 null（不传）。
String? minimaxEmotionOf(String? style) {
  final s = (style ?? '').toLowerCase();
  if (s.isEmpty) return null;
  if (RegExp('开心|高兴|活泼|撒娇|甜|欢快|happy').hasMatch(s)) return 'happy';
  if (RegExp('伤心|难过|悲|sad').hasMatch(s)) return 'sad';
  if (RegExp('生气|愤怒|angry').hasMatch(s)) return 'angry';
  if (RegExp('害怕|恐惧|fear').hasMatch(s)) return 'fearful';
  if (RegExp('惊讶|surprise').hasMatch(s)) return 'surprised';
  if (RegExp('耳语|悄悄|whisper').hasMatch(s)) return 'whisper';
  if (RegExp('平静|沉稳|温柔|从容|calm').hasMatch(s)) return 'calm';
  return null;
}

Future<Uint8List> minimaxSynthesize(MiniMaxTtsConfig c, String text, {String? emotion, double speed = 1.0, http.Client? client, Duration timeout = const Duration(seconds: 30)}) async {
  if (!c.configured) throw ProviderException('MiniMax 语音还没配好：要 API Key 和音色');
  if (text.trim().isEmpty) return Uint8List(0);
  final body = {
    'model': c.model,
    'text': text,
    'stream': false,
    'language_boost': 'Chinese',
    'voice_setting': {'voice_id': c.voice, 'speed': speed, 'vol': 1, 'pitch': 0, if (emotion != null && minimaxEmotions.contains(emotion)) 'emotion': emotion},
    'audio_setting': {'sample_rate': 32000, 'bitrate': 128000, 'format': 'mp3', 'channel': 1},
  };
  final uri = Uri.parse('${_trim(c.baseUrl)}/v1/t2a_v2${(c.groupId ?? '').isNotEmpty ? '?GroupId=${Uri.encodeComponent(c.groupId!)}' : ''}');
  final cl = client ?? http.Client();
  http.Response resp;
  try {
    resp = await cl.post(uri, headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${c.apiKey}'}, body: jsonEncode(body)).timeout(timeout);
  } on TimeoutException {
    throw ProviderException('timeout after ${timeout.inSeconds}s', retryable: true);
  } on http.ClientException catch (e) {
    throw ProviderException('network: ${e.message}', retryable: true);
  } finally {
    if (client == null) cl.close();
  }
  final text0 = utf8.decode(resp.bodyBytes, allowMalformed: true);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw ProviderException(providerErrorMessage(text0), status: resp.statusCode, retryable: resp.statusCode >= 500 || resp.statusCode == 429);
  }
  Object? j;
  try {
    j = jsonDecode(text0);
  } on FormatException {
    throw ProviderException('MiniMax 返回的不是 JSON：${text0.length > 160 ? text0.substring(0, 160) : text0}');
  }
  if (j is! Map) throw ProviderException('MiniMax 响应格式不对');
  final base = j['base_resp'];
  if (base is Map && (base['status_code'] as num?)?.toInt() != 0) {
    final code = base['status_code'];
    final msg = base['status_msg'] ?? '';
    throw ProviderException(switch (code) {
      1004 => '鉴权失败：$msg（检查 API Key）',
      1008 => '余额不足：$msg',
      _ => '$msg（$code）',
    });
  }
  final data = j['data'];
  final audio = data is Map ? data['audio'] : null;
  if (audio is! String || audio.isEmpty) throw ProviderException('MiniMax 没返回音频');
  return _hex(audio);
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _trim(String u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u;

int _seq = 0;
String _uuid() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(14, '0');
  final n = (++_seq).toRadixString(16).padLeft(4, '0');
  return 'yj$t$n';
}
