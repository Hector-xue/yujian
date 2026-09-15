import 'dart:convert';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  late Account wechat;
  late Account bank;
  const at = '2026-09-15T12:30:00+08:00';

  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 15, 4))..seedDefaultCategories();
    wechat = ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 10000);
    bank = ledger.createAccount(id: 'bank', name: '工行', type: AccountType.bank, currency: 'CNY');
    String c(Map<String, Object?> p) => ledger.commit(ledger.propose([DraftInput(payload: p)], source: Source.manual).single.id).id;
    c({'type': 'expense', 'amount_minor': 2850, 'currency': 'CNY', 'account_id': wechat.id, 'category_id': 'food', 'merchant': '面馆, 二楼', 'description': '午饭 "牛肉面"', 'occurred_at': at});
    c({'type': 'transfer', 'amount_minor': 5000, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': wechat.id, 'occurred_at': at});
    final v = c({'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': wechat.id, 'category_id': 'daily', 'occurred_at': at});
    ledger.commit(ledger.propose([DraftInput(kind: DraftKind.void_, targetTransactionId: v, payload: {'reason': 'x'})], source: Source.manual).single.id);
    ledger.commit(ledger.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 1900, 'currency': 'CNY', 'account_id': wechat.id, 'category_id': 'shopping', 'merchant': '瑞幸', 'occurred_at': at})], source: Source.chat).single.id, edits: {'category_id': 'food'});
  });
  tearDown(() => db.close());

  test('csv export escapes and lists confirmed only', () {
    final csv = exportCsv(ledger);
    expect(csv.startsWith('﻿id,date'), isTrue);
    final lines = const LineSplitter().convert(csv);
    expect(lines.length, 1 + 3); // 作废的不导
    expect(csv, contains('"面馆, 二楼"'));
    expect(csv, contains('"午饭 ""牛肉面"""'));
    expect(csv, contains(',transfer,50.00,CNY,,工行,微信,'));
  });

  test('json backup round-trips into an empty ledger', () {
    final j = exportJson(ledger);
    expect(j['format'], 'yujian-backup');
    expect((j['transactions'] as List).length, 4); // 含作废
    final text = jsonEncode(j);

    final db2 = openLedgerDatabaseInMemory();
    final l2 = Ledger(db2);
    final n = restoreFromJson(l2, jsonDecode(text) as Map<String, Object?>);
    expect(n, 4);
    expect(l2.balance('wechat').minor, ledger.balance('wechat').minor);
    expect(l2.balance('bank').minor, ledger.balance('bank').minor);
    expect(l2.listTransactions().length, 3);
    expect(l2.listCategories().length, 19);
    expect(l2.memory.get('瑞幸')!.categoryId, 'food');
    expect(l2.integrityCheck(), isEmpty);
    expect(l2.auditLog().first.action, 'ledger.restore');
    db2.close();
  });

  test('restore replaces existing data atomically; bad backup leaves ledger untouched', () {
    final before = exportJson(ledger);
    final bad = {...before, 'transactions': [{'id': 'x', 'type': 'expense', 'occurred_at': at, 'currency': 'CNY', 'postings': []}]};
    expect(() => restoreFromJson(ledger, bad), throwsA(isA<ValidationException>()));
    expect(ledger.listTransactions().length, 3); // 回滚了
    expect(() => restoreFromJson(ledger, {'format': 'other'}), throwsFormatException);
    expect(() => restoreFromJson(ledger, {'format': 'yujian-backup', 'version': 99}), throwsFormatException);
  });

  group('parseBillCsv', () {
    test('wechat export shape with preamble lines', () {
      const csv = '''微信支付账单明细
导出时间：[2026-09-15 12:00:00]
----------------------微信支付账单明细列表--------------------
交易时间,交易类型,交易对方,商品,收/支,支付方式,金额(元),当前状态,交易单号,商户单号,备注
2026-09-14 12:31:05,商户消费,瑞幸咖啡,"拿铁,大杯",支出,零钱,¥19.00,支付成功,42000001,,"/"
2026-09-14 20:10:00,转账,张三,转账,收入,/,¥200.00,已收钱,42000002,,"/"
2026-09-13 09:00:00,商户消费,滴滴出行,快车,支出,招商银行(1234),¥36.50,已全额退款,42000003,,"/"
2026-09-12 09:00:00,商户消费,美团,外卖,支出,零钱,¥32.50,支付成功,42000004,,"/"
''';
      final rows = parseBillCsv(csv);
      expect(rows.length, 3); // 全额退款的跳过
      expect(rows[0].type, 'expense');
      expect(rows[0].amountMinor, 1900);
      expect(rows[0].merchant, '瑞幸咖啡');
      expect(rows[0].description, '拿铁,大杯');
      expect(rows[0].accountHint, '零钱');
      expect(rows[0].occurredAt!.toIso8601String(), '2026-09-14T12:31:05.000+08:00');
      expect(rows[1].type, 'income');
      expect(rows[1].amountMinor, 20000);
      expect(rows[2].merchant, '美团');
      expect(rows[0].fingerprint, isNot(rows[2].fingerprint));
      expect(rows.every((r) => r.problems.isEmpty), isTrue);
    });

    test('alipay shape and yujian own csv', () {
      const alipay = '''交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注
2026-09-10 08:15:00,交通出行,滴滴出行,,快车,支出,24.00,花呗,交易成功,2026091000001,,
2026-09-10 18:00:00,餐饮美食,肯德基,,汉堡,支出,35.00,余额宝,交易成功,2026091000002,,
2026-09-11 10:00:00,转账,自己,,余额宝转出,不计收支,1000.00,余额宝,交易成功,2026091000003,,
''';
      final rows = parseBillCsv(alipay);
      expect(rows.length, 3);
      expect(rows[0].categoryHint, '交通出行');
      expect(rows[0].accountHint, '花呗');
      expect(rows[2].type, 'unknown');
      expect(rows[2].problems, contains('分不清收支'));

      final own = parseBillCsv(exportCsv(ledger));
      expect(own.length, 3);
      final noodle = own.firstWhere((r) => r.merchant == '面馆, 二楼');
      expect(noodle.amountMinor, 2850);
      expect(noodle.type, 'expense');
      expect(noodle.description, '午饭 "牛肉面"');
    });

    test('draft conversion and exact-fingerprint dedupe on re-import', () {
      const csv = '交易时间,交易对方,商品,收/支,金额\n2026-09-14 12:31:05,瑞幸,拿铁,支出,19.00\n';
      final rows = parseBillCsv(csv);
      final d1 = ledger.propose([importedRowToDraft(rows.single, accountId: wechat.id, categoryId: 'food')], source: Source.import_);
      expect(d1.length, 1);
      expect(d1.single.payload['amount_minor'], 1900);
      ledger.commit(d1.single.id);
      final d2 = ledger.propose([importedRowToDraft(rows.single, accountId: wechat.id, categoryId: 'food')], source: Source.import_);
      expect(d2, isEmpty); // 同一行再导：精确指纹丢弃
    });

    test('rejects files without a usable header', () {
      expect(() => parseBillCsv('a,b\n1,2\n'), throwsFormatException);
    });
  });
}
