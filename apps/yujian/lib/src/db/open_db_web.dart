import 'package:ledger_core/ledger_core.dart';
import 'package:sqlite3/wasm.dart';

String? lastOpenedPath = '浏览器 IndexedDB（yujian）';

Future<LedgerDatabase> open({bool inMemory = false}) async {
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  if (inMemory) {
    sqlite.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
    return LedgerDatabase.wrap(sqlite.openInMemory(), wal: false);
  }
  final fs = await IndexedDbFileSystem.open(dbName: 'yujian');
  sqlite.registerVirtualFileSystem(fs, makeDefault: true);
  return LedgerDatabase.wrap(sqlite.open('/yujian.db'), wal: false);
}
