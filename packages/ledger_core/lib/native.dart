/// 原生平台（dart:ffi）打开账本的入口。Web 端不要 import 这个文件。
library;

import 'package:sqlite3/sqlite3.dart';

import 'src/db/database.dart';

extension LedgerDatabaseNative on LedgerDatabase {
  static LedgerDatabase open(String path) => LedgerDatabase.wrap(sqlite3.open(path));
  static LedgerDatabase inMemory() => LedgerDatabase.wrap(sqlite3.openInMemory(), wal: false);
}

LedgerDatabase openLedgerDatabase(String path) => LedgerDatabase.wrap(sqlite3.open(path));
LedgerDatabase openLedgerDatabaseInMemory() => LedgerDatabase.wrap(sqlite3.openInMemory(), wal: false);
