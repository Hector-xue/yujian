import 'package:ledger_core/ledger_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

String? lastOpenedPath;

Future<LedgerDatabase> open({bool inMemory = false}) async {
  if (inMemory) return LedgerDatabase.wrap(sqlite3.openInMemory(), wal: false);
  final dir = await getApplicationSupportDirectory();
  lastOpenedPath = p.join(dir.path, 'yujian.db');
  return LedgerDatabase.wrap(sqlite3.open(lastOpenedPath!));
}
