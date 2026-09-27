import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:yujian/src/record_list.dart';

void main() {
  late Ledger ledger;

  setUp(() {
    ledger = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 9, 26, 4))..seedDefaultCategories();
    ledger.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 10000000);
    ledger.createAccount(id: 'usd', name: '美元', type: AccountType.bank, currency: 'USD', initialBalanceMinor: 100000);
  });

  Transaction add(Map<String, Object?> p) {
    final d = ledger.propose([DraftInput(payload: p)], source: Source.manual, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  Transaction spend(int minor, String at, {String currency = 'CNY'}) =>
      add({'type': 'expense', 'currency': currency, 'amount_minor': minor, 'account_id': currency == 'CNY' ? 'w' : 'usd', 'category_id': 'shopping', 'occurred_at': '$at+08:00'});

  List<Transaction> onDay(String d) => ledger.listTransactions().where((t) => t.occurredAt.localDate == d).toList();

  test('每日小计按币种分开、扣掉退款；只有退款写「退回」', () {
    final shoe = spend(30000, '2026-09-14T10:00:00');
    add({'type': 'refund', 'currency': 'CNY', 'amount_minor': 10000, 'account_id': 'w', 'refund_of_id': shoe.id, 'occurred_at': '2026-09-14T11:00:00+08:00'});
    spend(2000, '2026-09-14T12:00:00', currency: 'USD');
    expect(recordDaySummary(onDay('2026-09-14')), '支出 ¥200.00 + 20.00 USD');
    add({'type': 'refund', 'currency': 'CNY', 'amount_minor': 5000, 'account_id': 'w', 'refund_of_id': shoe.id, 'occurred_at': '2026-09-15T11:00:00+08:00'});
    expect(recordDaySummary(onDay('2026-09-15')), '退回 ¥50.00');
    expect(recordDaySummary(const []), '');
  });

  test('分页：被截在中间的最早那天补全，小计不会只算一半；更早还有就给「加载更多」', () {
    for (var i = 0; i < 6; i++) {
      spend(100, '2026-09-01T1$i:00:00');
    }
    for (var d = 2; d <= 6; d++) {
      spend(100, '2026-09-0${d}T12:00:00');
    }
    spend(100, '2026-08-31T12:00:00');
    final p = loadRecordPage(ledger, limit: 7); // 9/2–9/6 五笔 + 9/1 的两笔：9/1 被截在中间
    expect(p.txs.where((t) => t.occurredAt.localDate == '2026-09-01').length, 6);
    expect(p.txs.map((t) => t.id).toSet().length, p.txs.length);
    expect(p.hasMore, isTrue); // 8/31 还没取
    final all = loadRecordPage(ledger, limit: recordPageSize);
    expect(all.txs.length, 12);
    expect(all.hasMore, isFalse);
  });
}
