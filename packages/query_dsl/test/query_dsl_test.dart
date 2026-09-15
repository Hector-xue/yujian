import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';
import 'package:test/test.dart';

late LedgerDatabase db;
late Ledger ledger;
late Account wechat;
late Account bank;

String commit(Map<String, Object?> payload) =>
    ledger.commit(ledger.propose([DraftInput(payload: payload)], source: Source.manual).single.id).id;

Map<String, Object?> tx(String type, int amt, String when, {String? cat, String? account, String? merchant, String? refundOf}) => {
      'type': type,
      'amount_minor': amt,
      'currency': 'CNY',
      'account_id': account ?? wechat.id,
      if (cat != null) 'category_id': cat,
      if (merchant != null) 'merchant': merchant,
      if (refundOf != null) 'refund_of_id': refundOf,
      'occurred_at': '${when}T12:00:00+08:00',
    };

void main() {
  setUp(() {
    db = LedgerDatabase.inMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 15, 4))..seedDefaultCategories();
    ledger.createCategory(id: 'food.coffee', name: '咖啡', kind: CategoryKind.expense, parentId: 'food');
    wechat = ledger.createAccount(name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 100000);
    bank = ledger.createAccount(name: '工行', type: AccountType.bank, currency: 'CNY');
    commit(tx('expense', 2800, '2026-09-01', cat: 'food', merchant: '面馆'));
    commit(tx('expense', 1900, '2026-09-02', cat: 'food.coffee', merchant: '瑞幸'));
    commit(tx('expense', 2400, '2026-09-03', cat: 'transport'));
    commit(tx('expense', 22000, '2026-08-20', cat: 'housing', account: bank.id));
    commit(tx('income', 1500000, '2026-09-10', cat: 'salary', account: bank.id));
    final big = commit(tx('expense', 39900, '2026-09-12', cat: 'shopping', merchant: '耳机'));
    commit(tx('refund', 39900, '2026-09-13', refundOf: big));
    commit(tx('transfer', 5000, '2026-09-14')..['to_account_id'] = bank.id..remove('category_id'));
  });
  tearDown(() => db.close());

  test('sum expense this month nets refunds and excludes transfers/income', () {
    final r = QueryEngine(ledger).run(QueryDsl.fromJson({'metric': 'sum', 'time_range': {'from': '2026-09-01', 'to': '2026-09-30'}}));
    expect(r.rows.single.valueMinor, 2800 + 1900 + 2400 + 39900 - 39900);
    expect(r.rows.single.currency, 'CNY');
    expect(r.matchedCount, 5);
  });

  test('group by category expands subcategories in filter', () {
    final r = QueryEngine(ledger).run(QueryDsl.fromJson({
      'metric': 'sum',
      'time_range': {'from': '2026-09-01', 'to': '2026-09-30'},
      'filter': {'category_ids': ['food']},
      'group_by': 'category',
    }));
    expect(r.rows.map((x) => x.label).toSet(), {'餐饮', '咖啡'});
    expect(r.rows.fold<int>(0, (a, b) => a + b.valueMinor), 4700);
  });

  test('compare_to returns both periods', () {
    final r = QueryEngine(ledger).run(QueryDsl.fromJson({
      'metric': 'sum',
      'time_range': {'from': '2026-09-01', 'to': '2026-09-30'},
      'compare_to': {'from': '2026-08-01', 'to': '2026-08-31'},
    }));
    expect(r.rows.single.valueMinor, 7100);
    expect(r.compareRows!.single.valueMinor, 22000);
  });

  test('max points at the transaction', () {
    final r = QueryEngine(ledger).run(QueryDsl.fromJson({'metric': 'max', 'time_range': {'from': '2026-09-01', 'to': '2026-09-30'}, 'type': ['expense', 'refund']}));
    expect(r.rows.single.valueMinor, 39900);
    expect(r.rows.single.topTransactionId, isNotNull);
  });

  test('count / avg / by day / by account / merchant_like', () {
    final e = QueryEngine(ledger);
    expect(e.run(QueryDsl.fromJson({'metric': 'count', 'time_range': {'from': '2026-09-01', 'to': '2026-09-05'}})).rows.single.valueMinor, 3);
    expect(e.run(QueryDsl.fromJson({'metric': 'avg', 'time_range': {'from': '2026-09-01', 'to': '2026-09-05'}})).rows.single.valueMinor, (2800 + 1900 + 2400) ~/ 3);
    expect(e.run(QueryDsl.fromJson({'group_by': 'day', 'time_range': {'from': '2026-09-01', 'to': '2026-09-05'}})).rows.length, 3);
    expect(e.run(QueryDsl.fromJson({'group_by': 'account', 'type': ['income']})).rows.single.label, '工行');
    expect(e.run(QueryDsl.fromJson({'filter': {'merchant_like': '瑞幸'}})).rows.single.valueMinor, 1900);
  });

  test('balance metric reports account balances', () {
    final r = QueryEngine(ledger).run(QueryDsl.fromJson({'metric': 'balance'}));
    final byLabel = {for (final x in r.rows) x.label: x.valueMinor};
    expect(byLabel['微信'], 100000 - 2800 - 1900 - 2400 - 39900 + 39900 - 5000);
    expect(byLabel['工行'], -22000 + 1500000 + 5000);
  });

  test('invalid DSL is rejected before touching the ledger', () {
    expect(() => QueryDsl.fromJson({'metric': 'median'}), throwsFormatException);
    expect(() => QueryDsl.fromJson({'time_range': {'from': '2026-09-30', 'to': '2026-09-01'}}), throwsFormatException);
    expect(() => QueryDsl.fromJson({'time_range': {'from': '9/1', 'to': '9/30'}}), throwsFormatException);
    expect(() => QueryDsl.fromJson({'type': []}), throwsFormatException);
  });

  test('toJson round trip', () {
    final q = QueryDsl.fromJson({'metric': 'sum', 'group_by': 'month', 'filter': {'category_ids': ['food']}, 'limit': 5, 'order': 'asc'});
    expect(QueryDsl.fromJson(q.toJson()).toJson(), q.toJson());
  });
}
