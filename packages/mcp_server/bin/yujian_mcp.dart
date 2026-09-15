import 'dart:io';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:mcp_server/mcp_server.dart';

/// dart run mcp_server:yujian_mcp --db /path/to/yujian.db
/// 在 MCP 客户端（Claude Desktop / ivyea-agent 等）里配置为 stdio server。
Future<void> main(List<String> args) async {
  String? db;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--db') db = args[++i];
  }
  if (db == null || !File(db).existsSync()) {
    stderr.writeln('usage: yujian_mcp --db <yujian.db>（余见 App 「更多」页底部有路径）');
    exit(2);
  }
  final ledger = Ledger(openLedgerDatabase(db));
  await McpServer(ledger).serveStdio();
}
