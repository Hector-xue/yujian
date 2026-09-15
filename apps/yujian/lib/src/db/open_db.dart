import 'package:ledger_core/ledger_core.dart';

import 'open_db_native.dart' if (dart.library.js_interop) 'open_db_web.dart' as impl;

/// 平台相关的打开方式：原生走 dart:ffi + 文件；Web 走 wasm + IndexedDB。账本逻辑本身不区分平台。
Future<LedgerDatabase> openAppDatabase({bool inMemory = false}) => impl.open(inMemory: inMemory);

/// 当前账本文件路径（MCP server 要用）。
String? get appDatabasePath => impl.lastOpenedPath;
