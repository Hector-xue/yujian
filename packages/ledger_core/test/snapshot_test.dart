import 'dart:io';
import 'dart:typed_data';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:ledger_core/src/db/schema.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// SQLite 文件备份：快照出去的字节能原样恢复到另一个账本；坏文件被拒；恢复不带走别的设备的同步身份。
void main() {
  late Directory dir;
  late LedgerDatabase dbA;
  late Ledger a;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('yujian-snap');
    dbA = openLedgerDatabase('${dir.path}/a.db'); // 走文件 + WAL，和 App 一样
    a = Ledger(dbA)..seedDefaultCategories();
  });
  tearDown(() {
    dbA.db.close();
    dir.deleteSync(recursive: true);
  });

  Transaction record(Ledger l, String acc, int amount) => l.commit(l.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': amount, 'currency': 'CNY', 'account_id': acc, 'category_id': 'food', 'merchant': '面馆', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);

  test('snapshot round-trips into another ledger and drops sync identity', () async {
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    record(a, 'w', 2800);
    record(a, 'w', 1500);
    final deviceA = a.changes.deviceId;
    a.changes.lastPullSeq = 42;
    final bytes = snapshotDatabaseBytes(dbA);
    expect(String.fromCharCodes(bytes.sublist(0, 15)), 'SQLite format 3');
    // 快照后源库照常工作
    record(a, 'w', 100);
    expect(a.listTransactions().length, 3);

    final dbB = openLedgerDatabase('${dir.path}/b.db');
    final b = Ledger(dbB)..seedDefaultCategories();
    b.createAccount(id: 'old', name: '要被替换掉', type: AccountType.cash, currency: 'CNY');
    record(b, 'old', 999);
    final n = await restoreDatabaseBytes(dbB, bytes);
    expect(n, 2);
    expect(b.listTransactions().map((t) => t.amountMinor).toList(), [1500, 2800]);
    expect(b.account('old'), isNull);
    expect(b.account('w')?.name, '微信');
    expect(b.balance('w').minor, -4300);
    expect(b.changes.pending(), isEmpty);
    expect(b.changes.lastPullSeq, 0);
    expect(b.changes.deviceId, isNot(deviceA));
    // 恢复后还能继续写，且写入进变更日志
    record(b, 'w', 700);
    expect(b.changes.pendingCount, 2); // transaction + memory
    dbB.db.close();
  });

  test('rejects non-sqlite and foreign sqlite files', () async {
    await expectLater(restoreDatabaseBytes(dbA, Uint8List.fromList(List.filled(200, 7))), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('不是 SQLite'))));
    await expectLater(restoreDatabaseBytes(dbA, Uint8List.fromList('{"format":"yujian-backup"}'.codeUnits)), throwsA(isA<FormatException>()));
    final foreign = sqlite3.open('${dir.path}/foreign.db')..execute('CREATE TABLE t(x); INSERT INTO t VALUES (1);');
    foreign.close();
    await expectLater(restoreDatabaseBytes(dbA, File('${dir.path}/foreign.db').readAsBytesSync()), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('不是余见'))));
    // 被拒后原账本没被动
    expect(a.listCategories(), isNotEmpty);
  });

  test('restoring an older-schema file runs pending migrations', () async {
    // 只跑第 1 版迁移造一个"旧版本"文件
    final old = sqlite3.open('${dir.path}/old.db');
    old.execute('CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);');
    old.execute(migrations[1]!);
    old.execute('INSERT INTO schema_migrations VALUES (1, 0)');
    old.close();
    await restoreDatabaseBytes(dbA, File('${dir.path}/old.db').readAsBytesSync());
    expect(dbA.schemaVersion, migrations.keys.reduce((x, y) => x > y ? x : y));
    // 新表都在了：正常建账户、记账、进变更日志
    final l = Ledger(dbA)..seedDefaultCategories();
    l.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    record(l, 'w', 1);
    expect(l.changes.pendingCount, greaterThan(0));
  });
}
