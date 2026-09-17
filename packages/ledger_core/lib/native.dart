/// 原生平台（dart:ffi）打开账本的入口。Web 端不要 import 这个文件。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'src/db/database.dart';
import 'src/db/schema.dart';

extension LedgerDatabaseNative on LedgerDatabase {
  static LedgerDatabase open(String path) => LedgerDatabase.wrap(sqlite3.open(path));
  static LedgerDatabase inMemory() => LedgerDatabase.wrap(sqlite3.openInMemory(), wal: false);
}

LedgerDatabase openLedgerDatabase(String path) => LedgerDatabase.wrap(sqlite3.open(path));
LedgerDatabase openLedgerDatabaseInMemory() => LedgerDatabase.wrap(sqlite3.openInMemory(), wal: false);

/// 整库快照成 SQLite 文件字节（`VACUUM INTO`，含 WAL 里还没合并的页）。
Uint8List snapshotDatabaseBytes(LedgerDatabase ledgerDb) {
  final tmp = File(p.join(Directory.systemTemp.path, 'yujian-snapshot-${DateTime.now().microsecondsSinceEpoch}.db'));
  try {
    ledgerDb.db.execute('VACUUM INTO ?', [tmp.path]);
    return tmp.readAsBytesSync();
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}

/// 用一份 SQLite 备份整体替换当前账本。先校验是余见的库（文件头 + integrity_check + 有 schema_migrations/transactions 表），
/// 再走 sqlite backup API 覆盖进当前连接，补跑迁移，最后清掉同步痕迹（变更日志、设备号、拉取游标）——
/// 备份可能来自别的设备，带着它的身份继续同步会串。返回恢复后的已确认交易数。
Future<int> restoreDatabaseBytes(LedgerDatabase ledgerDb, Uint8List bytes) async {
  const header = [0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00]; // "SQLite format 3\0"
  if (bytes.length < 100 || !_startsWith(bytes, header)) throw const FormatException('不是 SQLite 文件');
  final tmp = File(p.join(Directory.systemTemp.path, 'yujian-restore-${DateTime.now().microsecondsSinceEpoch}.db'));
  tmp.writeAsBytesSync(bytes, flush: true);
  final src = sqlite3.open(tmp.path, mode: OpenMode.readOnly);
  try {
    final ok = src.select('PRAGMA integrity_check').first.columnAt(0);
    if (ok != 'ok') throw FormatException('文件已损坏：$ok');
    final tables = src.select("SELECT name FROM sqlite_master WHERE type = 'table'").map((r) => r['name'] as String).toSet();
    if (!tables.containsAll(const ['schema_migrations', 'transactions', 'accounts', 'categories'])) {
      throw const FormatException('不是余见的账本文件');
    }
    final v = src.select('SELECT MAX(version) AS v FROM schema_migrations').first['v'] as int? ?? 0;
    final latest = migrations.keys.reduce((a, b) => a > b ? a : b);
    if (v > latest) throw FormatException('备份的数据库版本 $v 比当前应用新，先升级应用');
    await src.backup(ledgerDb.db as Database).drain<void>();
  } finally {
    src.close();
    if (tmp.existsSync()) tmp.deleteSync();
  }
  ledgerDb.db.execute('PRAGMA foreign_keys = ON;');
  ledgerDb.migrate();
  ledgerDb.db.execute('DELETE FROM changes');
  ledgerDb.db.execute('DELETE FROM sync_state');
  return ledgerDb.db.select("SELECT COUNT(*) AS n FROM transactions WHERE status = 'confirmed'").first['n'] as int;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
