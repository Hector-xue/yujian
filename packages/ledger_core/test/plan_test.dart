import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;

  Transaction add(Map<String, Object?> payload) {
    final d = ledger.propose([DraftInput(payload: payload)], source: Source.manual, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  /// 工资卡起点 [startMinor]；7/25、8/25 各发 1 万工资（发薪日 25 号、月收入 1 万）；房贷每月 22 号 2000；
  /// 信用卡 5 号出账 24 号还：本期账单 1500（9/1 刷），出账后又刷了 500（进下期）。今天 9/20。
  Account setup(int startMinor) {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 20, 4))..seedDefaultCategories();
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: startMinor - 2000000);
    for (final d in ['2026-07-25', '2026-08-25']) {
      add({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'salary', 'occurred_at': '${d}T09:00:00+08:00'});
    }
    ledger.profile.payday = 25;
    ledger.debts.add(name: '房贷', kind: DebtKind.mortgage, owedMinor: 10000000, monthlyMinor: 200000, day: 22, fromAccountId: 'bank', today: '2026-09-20');
    final card = ledger.cards.add(name: '招行', terms: const CardTerms(limitMinor: 1000000, statementDay: 5, dueDay: 24));
    for (final (m, d) in [(150000, '2026-09-01'), (50000, '2026-09-10')]) {
      add({'type': 'expense', 'amount_minor': m, 'currency': 'CNY', 'account_id': card.id, 'category_id': 'shopping', 'occurred_at': '${d}T12:00:00+08:00'});
    }
    return card;
  }

  tearDown(() => db.close());

  test('排到第二个发薪日前一天：发薪 / 月供 / 本期账单 / 下期账单按日期排；钱不够全还信用卡就还能还的，月供保住', () {
    setup(300000);
    final p = RepaymentPlanner(ledger).build(today: '2026-09-20');
    expect(p.payday, '2026-09-25');
    expect(p.until, '2026-10-24');
    expect(p.monthlyIncomeMinor, 1000000);
    expect(p.startCashMinor, 300000);
    expect([for (final i in p.items) '${i.date} ${i.kind.name} ${i.payMinor} ${i.balanceAfterMinor}'], [
      '2026-09-22 loan 200000 100000',
      '2026-09-24 card 100000 0', // 账单 1500，发薪前只剩 1000：先还 1000（高于最低 150），发薪后再补
      '2026-09-25 income 1000000 1000000',
      '2026-10-22 loan 200000 800000',
      '2026-10-24 card 50000 750000', // 下期账单 = 出账后已经刷的 500
    ]);
    expect(p.items[1].fullMinor, 150000);
    expect(p.items[1].minMinor, 15000);
    expect(p.partialCards.single.name, '招行');
    expect(p.dueBeforePaydayFullMinor, 350000);
    expect(p.dueBeforePaydayMinMinor, 215000);
    expect(p.shortfallMinor, 0);
  });

  test('连月供都不够：信用卡只还最低，缺口照实算出来', () {
    setup(100000);
    final p = RepaymentPlanner(ledger).build(today: '2026-09-20');
    expect(p.items[0].balanceAfterMinor, -100000);
    expect(p.items[1].payMinor, 15000);
    expect(p.items[1].short, isTrue);
    expect(p.shortfallMinor, 115000);
  });

  test('日历标注：发薪日 / 月供 / 信用卡本期还款日（还剩多少）/ 下期账单日和还款日（约）', () {
    setup(300000);
    String fmt(DueMark d) => '${d.date} ${d.kind.name} ${d.name} ${d.amountMinor} ${d.note}';
    expect(dueMarks(ledger, from: '2026-09-01', to: '2026-09-30', today: '2026-09-20').map(fmt), [
      '2026-09-22 loan 房贷 还款 200000 ',
      '2026-09-24 cardDue 招行 150000 还剩',
      '2026-09-25 payday 发薪 null ',
    ]);
    expect(dueMarks(ledger, from: '2026-10-01', to: '2026-10-31', today: '2026-09-20').map(fmt), [
      '2026-10-05 cardStatement 招行 null 出账',
      '2026-10-22 loan 房贷 还款 200000 ',
      '2026-10-24 cardDue 招行 50000 约',
      '2026-10-25 payday 发薪 null ',
    ]);
  });
}
