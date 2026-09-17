import 'dart:typed_data';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';

const supported = true;
Uint8List snapshot(LedgerDatabase db) => snapshotDatabaseBytes(db);
Future<int> restore(LedgerDatabase db, Uint8List bytes) => restoreDatabaseBytes(db, bytes);
