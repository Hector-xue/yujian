import 'dart:convert';

import 'provider.dart';

/// 能力实测结果（§9.3）：不按厂商猜，真发请求。
class Capabilities {
  final bool chat;
  final bool jsonOutput;
  final bool? vision; // null = 没测
  final Duration? latency;
  final String? error;
  const Capabilities({required this.chat, required this.jsonOutput, this.vision, this.latency, this.error});

  Map<String, Object?> toJson() =>
      {'chat': chat, 'json_output': jsonOutput, 'vision': vision, 'latency_ms': latency?.inMilliseconds, 'error': error};
}

/// 8×8 纯红 PNG（看图探测用：问模型主色是什么）。
const probeImagePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFklEQVR4nGP4z8DwHwyBFIzNQBYDAJxvD/GDwQZpAAAAAElFTkSuQmCC';

class CapabilityProbe {
  /// 两次真实请求：普通对话；要求 JSON 的抽取（能否解析出指定字段）。
  static Future<Capabilities> run(ChatProvider p, {Duration timeout = const Duration(seconds: 30), bool testVision = false}) async {
    try {
      final r1 = await p.complete(system: 'Reply with exactly: OK', user: 'ping', timeout: timeout);
      final chat = r1.text.trim().isNotEmpty;
      bool? vision;
      if (testVision) {
        try {
          final rv = await p.completeWithImages(
            system: '只回答一个颜色词。',
            user: '这张图主要是什么颜色？',
            images: [ImageInput(base64Decode(probeImagePngBase64), 'image/png')],
            timeout: timeout,
          );
          vision = RegExp('红|red', caseSensitive: false).hasMatch(rv.text);
        } catch (_) {
          vision = false;
        }
      }
      var jsonOk = false;
      try {
        final r2 = await p.complete(
          system: '你是抽取器。只输出 JSON 对象，不要任何其他文字。',
          user: '从"午饭花了28元"里抽取金额，输出 {"amount": <数字>}',
          jsonMode: true,
          timeout: timeout,
        );
        final parsed = extractJsonObject(r2.text);
        jsonOk = parsed != null && (parsed['amount'] is num) && (parsed['amount'] as num) == 28;
      } catch (_) {
        jsonOk = false;
      }
      return Capabilities(chat: chat, jsonOutput: jsonOk, vision: vision, latency: r1.latency);
    } on ProviderException catch (e) {
      return Capabilities(chat: false, jsonOutput: false, error: e.toString());
    }
  }
}

/// 从模型输出里捞出第一个 JSON 对象：兼容 ```json 围栏、前后废话。解析失败返回 null。
Map<String, Object?>? extractJsonObject(String text) {
  var t = text.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true).firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  final start = t.indexOf('{');
  if (start < 0) return null;
  // 从第一个 { 开始配对括号，忽略字符串内的括号
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < t.length; i++) {
    final c = t[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) {
        try {
          final v = jsonDecode(t.substring(start, i + 1));
          return v is Map ? v.cast<String, Object?>() : null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}
