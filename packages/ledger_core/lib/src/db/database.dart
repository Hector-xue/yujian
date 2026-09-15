import 'package:sqlite3/common.dart';

import 'schema.dart';

/// 薄封装：迁移、事务。所有 SQL 由 ledger_core 持有，上层不直接碰库。
/// 只依赖 sqlite3 的 CommonDatabase，原生（dart:ffi）与 Web（wasm）都能用；
/// 打开数据库的方式由平台决定，见 `package:ledger_core/native.dart`。
class LedgerDatabase {
  final CommonDatabase db;

  /// 接管一个已打开的连接，跑迁移。
  LedgerDatabase.wrap(this.db, {bool wal = true}) {
    _init(wal: wal);
  }

  void _init({required bool wal}) {
    db.execute('PRAGMA foreign_keys = ON;');
    if (wal) db.execute('PRAGMA journal_mode = WAL;');
    db.execute('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);');
    final applied = db.select('SELECT version FROM schema_migrations').map((r) => r['version'] as int).toSet();
    final pending = migrations.keys.where((v) => !applied.contains(v)).toList()..sort();
    for (final v in pending) {
      transaction(() {
        db.execute(migrations[v]!);
        db.execute('INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
            [v, DateTime.now().toUtc().millisecondsSinceEpoch]);
      });
    }
  }

  int get schemaVersion =>
      db.select('SELECT MAX(version) AS v FROM schema_migrations').first['v'] as int? ?? 0;

  int _depth = 0;

  /// 可重入事务：最外层 BEGIN/COMMIT，内层只执行；任一层抛错整棵回滚。
  T transaction<T>(T Function() body) {
    if (_depth > 0) {
      _depth++;
      try {
        return body();
      } finally {
        _depth--;
      }
    }
    db.execute('BEGIN IMMEDIATE;');
    _depth = 1;
    try {
      final r = body();
      db.execute('COMMIT;');
      return r;
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    } finally {
      _depth = 0;
    }
  }

  ResultSet select(String sql, [List<Object?> params = const []]) => db.select(sql, params);
  void execute(String sql, [List<Object?> params = const []]) => db.execute(sql, params);

  void close() => db.dispose();
}
