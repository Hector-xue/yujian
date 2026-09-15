import 'dart:convert';

import 'provider.dart';

/// 能力实测结果（§9.3）：不按厂商猜，真发请求。
class Capabilities {
  final bool chat;
  final bool jsonOutput;
  final Duration? latency;
  final String? error;
  const Capabilities({required this.chat, required this.jsonOutput, this.latency, this.error});

  Map<String, Object?> toJson() =>
      {'chat': chat, 'json_output': jsonOutput, 'latency_ms': latency?.inMilliseconds, 'error': error};
}

class CapabilityProbe {
  /// 两次真实请求：普通对话；要求 JSON 的抽取（能否解析出指定字段）。
  static Future<Capabilities> run(ChatProvider p, {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final r1 = await p.complete(system: 'Reply with exactly: OK', user: 'ping', timeout: timeout);
      final chat = r1.text.trim().isNotEmpty;
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
      return Capabilities(chat: chat, jsonOutput: jsonOk, latency: r1.latency);
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
