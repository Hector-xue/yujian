import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 20, 4))..seedDefaultCategories();
  });
  tearDown(() => db.close());

  Transaction add(Map<String, Object?> payload) {
    final d = ledger.propose([DraftInput(payload: payload)], source: Source.manual, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  void spend(int minor, String date, {String account = 'bank'}) =>
      add({'type': 'expense', 'amount_minor': minor, 'currency': 'CNY', 'account_id': account, 'category_id': 'food', 'occurred_at': '${date}T12:00:00+08:00'});

  test('不缺钱：没负债、应急金够 → 资金规整成三份（应急金 6 个月 / 一年内要用的 / 长期闲钱）', () {
    // 近 3 个整月每月花 5000 → 应急金目标 6 × 5000 = 3 万；手头 30 万；一年内要用的目标还差 2 万
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 31500000);
    for (final d in ['2026-06-10', '2026-07-10', '2026-08-10']) {
      spend(500000, d);
    }
    ledger.goals.create(kind: GoalKind.wish, name: '换车', targetMinor: 2000000, deadline: '2027-06-01');
    ledger.goals.create(kind: GoalKind.wish, name: '十年后', targetMinor: 9900000, deadline: '2036-01-01');
    final c = Checkups(ledger).run(today: '2026-09-20');
    expect(c.m.liquidMinor, 30000000);
    expect(c.emergencyTargetMinor, 3000000);
    expect(c.highInterestMinor, 0);
    expect(c.buckets, isNotNull);
    expect(c.buckets!.emergencyMinor, 3000000);
    expect(c.buckets!.nearTermMinor, 2000000);
    expect(c.buckets!.longTermMinor, 30000000 - 3000000 - 2000000);
    expect(c.hasBad, isFalse);
    expect(c.steps.map((s) => s.title).join('|'), contains('长期闲钱'));
  });

  test('负债重：逾期排第一步、高息先还；不给资金规整', () {
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
    spend(300000, '2026-08-10', account: 'bank');
    final card = ledger.cards.add(name: '花呗', terms: CreditProduct.huabei.defaults(limitMinor: 500000).copyWith(statementDay: 1, dueDay: 9), owedMinor: 400000);
    ledger.debts.add(name: '某网贷', kind: DebtKind.online, owedMinor: 2000000, today: '2026-09-20');
    final c = Checkups(ledger).run(today: '2026-09-20');
    expect(ledger.cards.status(card.id, today: '2026-09-20')!.state, CardBillState.overdue);
    expect(c.steps.first.title, '先把逾期的还上');
    expect(c.steps.map((s) => s.title), contains('高息的先还'));
    expect(c.highInterestMinor, greaterThanOrEqualTo(2000000 + 400000));
    expect(c.buckets, isNull);
    expect(c.hasBad, isTrue);
    expect(c.findings.first.tone, CheckTone.bad);
  });
}
