import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ledger_core/ledger_core.dart';

import 'tools.dart';

const mcpProtocolVersion = '2025-06-18';

/// 最小 MCP 服务端：initialize / tools/list / tools/call / ping。一次一行 JSON-RPC。
class McpServer {
  final LedgerTools tools;
  final String serverName;
  final String version;
  McpServer(Ledger ledger, {this.serverName = 'yujian', this.version = '0.2.0', String Function()? today}) : tools = LedgerTools(ledger, today: today);

  /// 处理一条消息；通知（无 id）返回 null。
  Map<String, Object?>? handle(Map<String, Object?> msg) {
    final id = msg['id'];
    final method = msg['method'] as String?;
    final params = (msg['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (method == null) return null;
    Map<String, Object?> ok(Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
    Map<String, Object?> err(int code, String message) => {'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message}};
    switch (method) {
      case 'initialize':
        return ok({
          'protocolVersion': mcpProtocolVersion,
          'capabilities': {'tools': {'listChanged': false}},
          'serverInfo': {'name': serverName, 'version': version},
          'instructions': '余见账本。写入只能 propose_*，会进用户收件箱等待确认；不要假设已入账。金额用十进制字符串。',
        });
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return null;
      case 'ping':
        return ok({});
      case 'tools/list':
        return ok({'tools': toolDefs.map((t) => t.toJson()).toList()});
      case 'tools/call':
        final name = params['name'] as String?;
        final args = (params['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
        if (name == null) return err(-32602, 'name required');
        try {
          final r = tools.call(name, args);
          return ok({'content': [{'type': 'text', 'text': jsonEncode(r)}], 'isError': false});
        } catch (e) {
          return ok({'content': [{'type': 'text', 'text': '$e'}], 'isError': true});
        }
      default:
        return id == null ? null : err(-32601, 'method not found: $method');
    }
  }

  /// stdio 循环：每行一条 JSON。
  Future<void> serveStdio({Stream<List<int>>? input, IOSink? output}) async {
    final out = output ?? stdout;
    final lines = (input ?? stdin).transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, Object?> msg;
      try {
        msg = (jsonDecode(line) as Map).cast<String, Object?>();
      } catch (_) {
        out.writeln(jsonEncode({'jsonrpc': '2.0', 'id': null, 'error': {'code': -32700, 'message': 'parse error'}}));
        continue;
      }
      final resp = handle(msg);
      if (resp != null) out.writeln(jsonEncode(resp));
    }
  }
}
