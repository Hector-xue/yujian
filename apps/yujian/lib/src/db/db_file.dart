import 'dart:typed_data';

import 'package:ledger_core/ledger_core.dart';

import 'db_file_native.dart' if (dart.library.js_interop) 'db_file_web.dart' as impl;

/// SQLite 文件级备份 / 恢复。只有原生端有文件；Web 端用 JSON 备份。
bool get sqliteFileSupported => impl.supported;
Uint8List snapshotDatabase(LedgerDatabase db) => impl.snapshot(db);
Future<int> restoreDatabase(LedgerDatabase db, Uint8List bytes) => impl.restore(db, bytes);
