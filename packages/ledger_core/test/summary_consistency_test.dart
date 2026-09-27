import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 用户眼前看得到的汇总数字，各页面之间必须对得上：同一笔钱在两个页面上是两个数，就是 bug。
void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  const today = '2026-09-26';

  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 26, 4))..seedDefaultCategories();
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 500000);
    ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    ledger.createAccount(id: 'yeb', name: '余额宝', type: AccountType.investment, currency: 'CNY', initialBalanceMinor: 200000);
  });
  tearDown(() => db.close());

  Transaction add(Map<String, Object?> p) {
    final d = ledger.propose([DraftInput(payload: {'currency': 'CNY', ...p})], source: Source.manual, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  void spend(int minor, String account, String date) =>
      add({'type': 'expense', 'amount_minor': minor, 'account_id': account, 'category_id': 'shopping', 'occurred_at': '${date}T12:00:00+08:00'});

  test('净资产 = 资产 − 负债 严格成立：透支成负的钱包照减进资产，信用卡多还进去的算资产', () {
    spend(5000, 'wechat', '2026-09-20'); // 微信没填期初余额：花成 −50
    ledger.cards.add(name: '招行', terms: const CardTerms(limitMinor: 800000, statementDay: 16, dueDay: 6), owedMinor: 300000);
    final over = ledger.cards.add(name: '中行', terms: const CardTerms(limitMinor: 100000, statementDay: 5, dueDay: 25));
    add({'type': 'transfer', 'amount_minor': 20000, 'account_id': 'bank', 'to_account_id': over.id, 'occurred_at': '2026-09-21T12:00:00+08:00'}); // 溢缴 200
    ledger.debts.add(name: '安逸花', kind: DebtKind.online, owedMinor: 170199, monthlyMinor: 18911, day: 26, fromAccountId: 'bank', today: '2026-09-01');
    final m = Wealth(ledger).compute(today: today);
    expect(m.netWorthMinor, m.assetsMinor - m.debt.totalMinor);
    // 资产 = 工资卡 4800 + 微信 −50 + 余额宝 2000 + 溢缴 200
    expect(m.assetsMinor, 480000 - 5000 + 200000 + 20000);
    expect(m.debt.totalMinor, 300000 + 170199);
  });

  test('真锁仓放在余额宝（投资账户）：不在手头余额里，不再从可花的里扣；放在银行卡：照扣', () {
    final before = Wealth(ledger).compute(today: today);
    ledger.goals.create(kind: GoalKind.wish, name: '旅行', targetMinor: 300000, vaultAccountId: 'yeb');
    final m = Wealth(ledger).compute(today: today);
    expect(m.lockedMinor, 0);
    expect(m.disposableMinor, before.disposableMinor);
    // 银行卡当锁仓：它的钱在手头余额里，锁住了就不能算可花
    ledger.createAccount(id: 'save', name: '存钱卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
    final base = Wealth(ledger).compute(today: today);
    ledger.goals.create(kind: GoalKind.wish, name: '换车', targetMinor: 1000000, vaultAccountId: 'save');
    final m2 = Wealth(ledger).compute(today: today);
    expect(m2.lockedMinor, 100000);
    expect(m2.disposableMinor, base.disposableMinor - 100000);
    // 还款计划的起点和可花的同一个口径
    expect(RepaymentPlanner(ledger).build(today: today, metrics: m2).startCashMinor, m2.cashMinor - m2.lockedMinor);
  });

  test('真锁仓只能是存钱的账户：信用卡 / 贷款当锁仓直接拒', () {
    final card = ledger.cards.add(name: '招行', terms: const CardTerms(limitMinor: 800000, statementDay: 16, dueDay: 6));
    expect(() => ledger.goals.create(kind: GoalKind.wish, name: 'x', targetMinor: 100, vaultAccountId: card.id), throwsA(isA<ValidationException>()));
    final g = ledger.goals.create(kind: GoalKind.wish, name: 'y', targetMinor: 100);
    expect(() => ledger.goals.setVault(g.id, card.id), throwsA(isA<ValidationException>()));
    expect(GoalStore.canBeVault(AccountType.investment), isTrue);
    expect(GoalStore.canBeVault(AccountType.payable), isFalse);
  });

  test('还清目标的「还欠」永远等于负债页这个账户欠多少：欠款涨过建目标时的数也跟着走', () {
    final card = ledger.cards.add(name: '招行', terms: const CardTerms(limitMinor: 800000, statementDay: 16, dueDay: 6), owedMinor: 811828);
    final g = ledger.goals.create(kind: GoalKind.payoff, name: '还清招行', targetMinor: 811828, linkedAccountId: card.id, withVault: false);
    int owed() => ledger.debts.list().firstWhere((d) => d.account.id == card.id).owedMinor;
    spend(50000, card.id, '2026-09-25');
    var p = ledger.goals.progress(g, today: today);
    expect(p.remainingMinor, owed());
    expect(p.remainingMinor, 861828);
    expect(p.savedMinor, 0);
    // 还一部分：已还按建目标时的数算，还欠照样等于欠款
    add({'type': 'transfer', 'amount_minor': 100000, 'account_id': 'bank', 'to_account_id': card.id, 'occurred_at': '2026-09-26T09:00:00+08:00'});
    p = ledger.goals.progress(g, today: today);
    expect(p.remainingMinor, owed());
    expect(p.savedMinor, 811828 - 761828);
  });

  test('还款计划「到发薪日为止要付的」固定支出 + 月供 = 可花的里扣的：发薪当天到期的、收件箱里没确认的都算', () {
    ledger.profile.payday = 10;
    ledger.debts.add(name: '安逸花', kind: DebtKind.online, owedMinor: 170199, monthlyMinor: 18911, day: 26, fromAccountId: 'bank', today: '2026-09-01');
    ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 200000, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-10-10');
    ledger.recurring.create(name: '话费', template: {'type': 'expense', 'amount_minor': 5000, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'shopping'}, frequency: Frequency.monthly, firstDue: '2026-09-20');
    ledger.recurring.generateDue(today: today, tzOffsetMinutes: 480); // 话费、今天的安逸花：草稿躺在收件箱
    final m = Wealth(ledger).compute(today: today);
    expect(m.payday, '2026-10-10');
    expect(m.fixedDueMinor, 200000 + 5000 + 18911);
    final plan = RepaymentPlanner(ledger).build(today: today, metrics: m);
    expect(plan.fixedDueBeforePaydayMinor, m.fixedDueMinor);
    // 已经过了日子的待确认账单挂今天，不会跑到过去
    final phone = plan.items.firstWhere((i) => i.name == '话费' && i.date == today);
    expect(phone.fullMinor, 5000);
    expect(plan.items.where((i) => i.kind == PlanItemKind.loan).map((i) => i.date), containsAll([today, '2026-10-26']));
    // 确认了话费：两边一起少
    final draft = ledger.listDrafts(status: DraftStatus.pending).firstWhere((d) => d.payload['description'] == '话费');
    ledger.commit(draft.id);
    final m2 = Wealth(ledger).compute(today: today);
    expect(m2.fixedDueMinor, 200000 + 18911);
    expect(RepaymentPlanner(ledger).build(today: today, metrics: m2).fixedDueBeforePaydayMinor, m2.fixedDueMinor);
  });
}
