import 'dart:typed_data';

import 'package:ledger_core/ledger_core.dart';

const supported = false;
Uint8List snapshot(LedgerDatabase db) => throw UnsupportedError('浏览器版没有账本文件，请用 JSON 备份');
Future<int> restore(LedgerDatabase db, Uint8List bytes) => throw UnsupportedError('浏览器版没有账本文件，请用 JSON 备份');
