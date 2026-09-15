import 'dart:convert';
import 'dart:io';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:sync_client/sync_client.dart';
import 'package:test/test.dart';

/// 假服务端：与 server/app/main.py 同一契约。
class FakeServer {
  late HttpServer server;
  final changes = <Map<String, Object?>>[];
  List<int>? backup;
  int backupAt = 0;
  String? backupDevice;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final auth = req.headers.value('authorization');
      if (req.uri.path != '/healthz' && auth != 'Bearer tok') {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      Object? out;
      if (req.uri.path == '/healthz') {
        out = {'ok': true};
      } else if (req.uri.path == '/api/v1/sync/push') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        for (final c in (body['changes'] as List).cast<Map>()) {
          changes.add({...c.cast<String, Object?>(), 'seq': changes.length + 1, 'device_id': body['device_id']});
        }
        out = {'accepted': (body['changes'] as List).length, 'server_seq': changes.length};
      } else if (req.uri.path == '/api/v1/sync/pull') {
        final dev = req.uri.queryParameters['device_id'];
        final since = int.parse(req.uri.queryParameters['since'] ?? '0');
        final limit = int.parse(req.uri.queryParameters['limit'] ?? '500');
        final rows = changes.where((c) => (c['seq'] as int) > since && c['device_id'] != dev).take(limit).toList();
        final next = rows.isEmpty ? (since > changes.length ? since : changes.length) : rows.last['seq'] as int;
        out = {'changes': rows, 'next_since': next, 'server_seq': changes.length, 'has_more': rows.length == limit && next < changes.length};
      } else if (req.uri.path == '/api/v1/backup' && req.method == 'PUT') {
        backup = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        backupAt = DateTime.now().millisecondsSinceEpoch;
        backupDevice = req.headers.value('x-device');
        out = {'name': 'default', 'size': backup!.length, 'updated_at': backupAt};
      } else if (req.uri.path == '/api/v1/backup' && req.method == 'GET') {
        if (backup == null) {
          req.response.statusCode = 404;
        } else {
          req.response.headers.contentType = ContentType.binary;
          req.response.add(backup!);
        }
        await req.response.close();
        return;
      } else if (req.uri.path == '/api/v1/backup/info') {
        if (backup == null) {
          req.response.statusCode = 404;
        } else {
          out = {'name': 'default', 'size': backup!.length, 'updated_at': backupAt, 'device_id': backupDevice};
        }
      }
      if (out != null) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(out));
      }
      await req.response.close();
    });
  }

  String get url => 'http://127.0.0.1:${server.port}';
}

void main() {
  late FakeServer s;
  final base = DateTime.utc(2026, 9, 15, 4).millisecondsSinceEpoch;
  var clock = 0;
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(base + clock, isUtc: true);
  Ledger mk() => Ledger(openLedgerDatabaseInMemory(), clock: now)..seedDefaultCategories();

  setUp(() async {
    s = FakeServer();
    await s.start();
    clock = 0;
  });
  tearDown(() => s.server.close(force: true));

  SyncClient client(Ledger l, {String token = 'tok'}) => SyncClient(l, SyncConfig(baseUrl: s.url, token: token));

  test('two devices converge through the relay', () async {
    final a = mk();
    final b = mk();
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 10000);
    a.commit(a.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'food', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);
    final ra = await client(a).sync();
    expect(ra.pushed, 2);
    expect(ra.pulled, 0);
    final rb = await client(b).sync();
    expect(rb.pulled, 2);
    expect(rb.applied, 2);
    expect(b.balance('w').minor, 7200);
    // b 记一笔 → a 拉到；再同步各自零动作
    clock = 1000;
    b.commit(b.propose([DraftInput(payload: {'type': 'income', 'amount_minor': 5000, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'salary', 'occurred_at': '2026-09-15T13:00:00+08:00'})], source: Source.chat).single.id);
    await client(b).sync();
    final ra2 = await client(a).sync();
    expect(ra2.applied, 1);
    expect(a.balance('w').minor, 12200);
    expect((await client(a).sync()).toString(), '推 0 · 拉 0 · 应用 0 · 冲突跳过 0');
    expect((await client(b).sync()).pulled, 0);
    expect(a.integrityCheck(), isEmpty);
    expect(b.integrityCheck(), isEmpty);
  });

  test('conflict: later edit wins on both sides', () async {
    final a = mk();
    final b = mk();
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    final tx = a.commit(a.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'food', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);
    await client(a).sync();
    await client(b).sync();
    clock = 2000;
    b.commit(b.propose([DraftInput(kind: DraftKind.update, targetTransactionId: tx.id, payload: {'category_id': 'daily'})], source: Source.manual).single.id);
    clock = 3000;
    a.commit(a.propose([DraftInput(kind: DraftKind.update, targetTransactionId: tx.id, payload: {'category_id': 'transport'})], source: Source.manual).single.id);
    await client(b).sync();
    final ra = await client(a).sync();
    expect(ra.skipped, 1);
    await client(b).sync();
    expect(a.getTransaction(tx.id).categoryId, 'transport');
    expect(b.getTransaction(tx.id).categoryId, 'transport');
  });

  test('bad token and unreachable server surface as SyncException; nothing marked pushed', () async {
    final a = mk();
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    await expectLater(client(a, token: 'nope').sync(), throwsA(isA<SyncException>().having((e) => e.status, 'status', 401)));
    expect(a.changes.pendingCount, 1);
    final dead = SyncClient(a, const SyncConfig(baseUrl: 'http://127.0.0.1:1', token: 'tok'), timeout: const Duration(seconds: 2));
    expect(await dead.ping(), isFalse);
    await expectLater(dead.sync(), throwsA(isA<SyncException>()));
  });

  test('encrypted backup round trip; wrong passphrase rejected; server never sees plaintext', () async {
    final a = mk();
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 123);
    final info = await client(a).uploadBackup('correct horse');
    expect(info.size, greaterThan(100));
    expect(utf8.decode(s.backup!, allowMalformed: true), isNot(contains('微信')));
    expect(String.fromCharCodes(s.backup!.sublist(0, 4)), 'YJB1');
    final b = mk();
    await expectLater(client(b).restoreBackup('wrong'), throwsFormatException);
    expect(b.listAccounts(includeArchived: true), isEmpty);
    final n = await client(b).restoreBackup('correct horse');
    expect(n, 0);
    expect(b.getAccount('w').initialBalanceMinor, 123);
    expect((await client(b).backupInfo())!.deviceId, a.changes.deviceId);
  });

  test('BackupCrypto rejects garbage and short passphrases', () async {
    expect(() => BackupCrypto.encrypt('x', 'short'), throwsArgumentError);
    await expectLater(BackupCrypto.decrypt([1, 2, 3], 'whatever'), throwsFormatException);
  });
}
