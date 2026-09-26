import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  late Account wechat;
  late Account bank;

  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 20, 4))..seedDefaultCategories();
    wechat = ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 3000000);
    bank = ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 2000000);
  });
  tearDown(() => db.close());

  Transaction add(Map<String, Object?> payload, {String? fingerprint}) {
    final d = ledger.propose([DraftInput(payload: payload, eventFingerprint: fingerprint, fingerprintIsExact: fingerprint != null)], source: Source.manual, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  Map<String, Object?> expense(int minor, String date, {String? cat, String? merchant, String account = 'wechat'}) =>
      {'type': 'expense', 'amount_minor': minor, 'currency': 'CNY', 'account_id': account, 'category_id': cat ?? 'food', 'merchant': merchant, 'occurred_at': '${date}T12:00:00+08:00'};
  Map<String, Object?> income(int minor, String date, {String cat = 'salary'}) => {'type': 'income', 'amount_minor': minor, 'currency': 'CNY', 'account_id': 'bank', 'category_id': cat, 'occurred_at': '${date}T09:00:00+08:00'};

  group('goals', () {
    test('wish goal gets a virtual vault; deposits are real transfers; progress / milestones / pace; vault hidden from account lists', () {
      final g = ledger.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 699900, emoji: '📱', deadline: '2027-03-01');
      expect(g.isVirtualVault, isTrue);
      expect(g.vaultAccountId, 'vault:${g.id}');
      expect(ledger.listAccounts().map((a) => a.id), isNot(contains(g.vaultAccountId)));
      expect(ledger.listAccounts(includeVault: true).map((a) => a.id), contains(g.vaultAccountId));
      expect(ledger.achievements.list(), isEmpty);

      final t = add(ledger.goals.depositPayload(g, 100000, fromAccountId: wechat.id));
      expect(t.type, TransactionType.transfer);
      expect(t.toAccountId, g.vaultAccountId);
      expect(ledger.balance(wechat.id).minor, 2900000);
      expect(ledger.goals.savedMinor(g), 100000);
      final p = ledger.goals.progress(g, today: '2026-09-20');
      expect(p.ratio, closeTo(100000 / 699900, 1e-9));
      expect(p.milestone, 10);
      expect(p.paceMinorPerDay, closeTo(100000 / 30, 1e-6));
      expect(p.etaDays, ((699900 - 100000) / (100000 / 30)).ceil());
      expect(p.behindDays, isNotNull);
      expect(ledger.goals.deposits(g.id).single.id, t.id);
      // 审计里有 goal.create，同步日志里有 goal 实体
      expect(ledger.auditLog().any((e) => e.action == 'goal.create'), isTrue);
      expect(ledger.changes.pending().any((c) => c.entity == 'goal'), isTrue);
    });

    test('remove: never-funded goal takes its vault account with it; a funded one must be released first, then the vault is archived', () {
      // 没存过钱：目标 + 锁仓账户一起真删，同步日志记两条删除
      final fresh = ledger.goals.create(kind: GoalKind.wish, name: '旅行', targetMinor: 500000);
      final r1 = ledger.goals.remove(fresh.id);
      expect(r1.vaultDeleted, isTrue);
      expect(r1.postingCount, 0);
      expect(ledger.goals.find(fresh.id), isNull);
      expect(ledger.account(fresh.vaultAccountId!), isNull);
      expect(ledger.changes.pending().where((c) => c.deleted && (c.entityId == fresh.id || c.entityId == fresh.vaultAccountId)).length, 2);
      // 存过钱：钱还在锁仓里就拒绝；释放回来源后再删，锁仓账户归档留历史（余额 0、不在账户列表里）
      final g = ledger.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 699900);
      add(ledger.goals.depositPayload(g, 100000, fromAccountId: wechat.id));
      expect(() => ledger.goals.remove(g.id), throwsA(isA<InvalidStateException>()));
      for (final b in ledger.goals.releasePayloads(g, fallbackAccountId: wechat.id)) {
        add(b);
      }
      expect(ledger.goals.savedMinor(g), 0);
      expect(ledger.balance(wechat.id).minor, 3000000);
      final r2 = ledger.goals.remove(g.id);
      expect(r2.vaultDeleted, isFalse);
      expect(r2.postingCount, 2);
      expect(ledger.goals.find(g.id), isNull);
      expect(ledger.account(g.vaultAccountId!)!.isArchived, isTrue);
      expect(ledger.listAccounts(includeVault: true).map((a) => a.id), isNot(contains(g.vaultAccountId)));
      // 真锁仓（用户自己的账户）：删目标不碰账户
      final real = ledger.goals.create(kind: GoalKind.wish, name: '买车', targetMinor: 20000000, vaultAccountId: bank.id);
      expect(real.isVirtualVault, isFalse);
      ledger.goals.remove(real.id);
      expect(ledger.account(bank.id), isNotNull);
    });

    test('redeem spends from the vault (multiple), completion releases the rest to sources proportionally', () {
      final g = ledger.goals.create(kind: GoalKind.wish, name: '日本游', targetMinor: 1200000);
      add(ledger.goals.depositPayload(g, 300000, fromAccountId: wechat.id));
      add(ledger.goals.depositPayload(g, 900000, fromAccountId: bank.id));
      expect(ledger.goals.progress(g, today: '2026-09-20').reached, isTrue);
      add(ledger.goals.redeemPayload(g, 500000, categoryId: 'travel', merchant: '航空公司'));
      add(ledger.goals.redeemPayload(g, 300000, categoryId: 'travel', merchant: '酒店'));
      expect(ledger.goals.redemptions(g.id).length, 2);
      expect(ledger.goals.savedMinor(g), 400000);
      // 剩 4000 按 3:9 回来源
      final backs = ledger.goals.releasePayloads(g, fallbackAccountId: wechat.id);
      expect(backs.length, 2);
      final byTo = {for (final b in backs) b['to_account_id']: b['amount_minor']};
      expect(byTo[wechat.id], 100000);
      expect(byTo[bank.id], 300000);
      for (final b in backs) {
        add(b);
      }
      expect(ledger.goals.savedMinor(g), 0);
      ledger.goals.update(g.id, status: GoalStatus.done);
      expect(ledger.goals.get(g.id).status, GoalStatus.done);
      expect(ledger.goals.get(g.id).doneAt, isNotNull);
      expect(ledger.goals.list(), isEmpty);
      expect(ledger.goals.list(activeOnly: false).length, 1);
    });

    test('payoff goal needs a debt account; progress follows the balance', () {
      expect(() => ledger.goals.create(kind: GoalKind.payoff, name: '还花呗', targetMinor: 0, linkedAccountId: wechat.id), throwsA(isA<ValidationException>()));
      final huabei = ledger.createAccount(id: 'huabei', name: '花呗', type: AccountType.payable, currency: 'CNY', initialBalanceMinor: -300000);
      final g = ledger.goals.create(kind: GoalKind.payoff, name: '还花呗', targetMinor: 0, linkedAccountId: huabei.id);
      expect(g.targetMinor, 300000);
      expect(g.vaultAccountId, isNull);
      expect(ledger.goals.progress(g, today: '2026-09-20').savedMinor, 0);
      add({'type': 'transfer', 'amount_minor': 100000, 'currency': 'CNY', 'account_id': 'bank', 'to_account_id': 'huabei', 'occurred_at': '2026-09-20T10:00:00+08:00'});
      final p = ledger.goals.progress(g, today: '2026-09-20');
      expect(p.savedMinor, 100000);
      expect(p.ratio, closeTo(1 / 3, 1e-9));
    });

    test('rules: fixed due once per period with fingerprint, roundup settles weekly as one deposit, payday plan honors priority and shortfall', () {
      final a = ledger.goals.create(kind: GoalKind.wish, name: 'A', targetMinor: 1000000, rules: const [GoalRule(kind: GoalRuleKind.salaryPct, pct: 20), GoalRule(kind: GoalRuleKind.fixed, amountMinor: 50000, every: 'monthly', day: 10)]);
      final b = ledger.goals.create(kind: GoalKind.wish, name: 'B', targetMinor: 1000000, rules: const [GoalRule(kind: GoalRuleKind.salaryPct, pct: 30), GoalRule(kind: GoalRuleKind.roundup, roundTo: 1000)]);
      // 目标 9/20 才建：9/10 那期不倒扣
      expect(ledger.goals.dueFixed(today: '2026-09-20'), isEmpty);
      // 定额：不到 10 号不到期
      expect(ledger.goals.dueFixed(today: '2026-10-09'), isEmpty);
      final due = ledger.goals.dueFixed(today: '2026-10-10');
      expect(due.single.amountMinor, 50000);
      expect(due.single.fingerprint, 'goal:${a.id}:fixed:2026-10');
      // 10 号没打开 App：当月之后哪天打开都补上
      expect(ledger.goals.dueFixed(today: '2026-10-23').single.fingerprint, 'goal:${a.id}:fixed:2026-10');
      // 存了这期之后同月不再到期
      add(ledger.goals.depositPayload(a, 50000, fromAccountId: wechat.id), fingerprint: due.single.fingerprint);
      expect(ledger.goals.dueFixed(today: '2026-10-23'), isEmpty);
      // 零头：上周（9/14–9/20）支出 28 + 36.5 + 100 → 零头 2 + 3.5 + 0 = 5.5
      add(expense(2800, '2026-09-14'));
      add(expense(3650, '2026-09-16'));
      add(expense(10000, '2026-09-19'));
      final ru = ledger.goals.roundupDue(weekMonday: '2026-09-14');
      expect(ru.single.goal.id, b.id);
      expect(ru.single.amountMinor, (1000 - 2800 % 1000) + (1000 - 3650 % 1000)); // 2 元 + 3.5 元，整百的 100 元不算
      // 发薪：10000 元，A 20% + 定额 500，B 30%；可用只有 3000 → A 拿 2000+500，B 只拿 500
      final plan = ledger.goals.paydayPlan(1000000, availableMinor: 300000);
      expect(plan.map((x) => x.amountMinor).toList(), [200000, 50000, 50000]);
      expect(plan.last.short, isTrue);
      expect(plan.last.wantedMinor, 300000);
    });

    test('reorder, update name renames the vault, sync upsert/delete raw', () {
      final a = ledger.goals.create(kind: GoalKind.wish, name: 'A', targetMinor: 100);
      final b = ledger.goals.create(kind: GoalKind.wish, name: 'B', targetMinor: 100);
      ledger.goals.reorder([b.id, a.id]);
      expect(ledger.goals.list().map((g) => g.name).toList(), ['B', 'A']);
      ledger.goals.update(a.id, name: '改名');
      expect(ledger.getAccount(a.vaultAccountId!).name, '改名');
      ledger.goals.upsertRaw({'id': 'remote1', 'kind': 'wish', 'name': 'R', 'target_minor': 5, 'currency': 'CNY', 'rules': [], 'priority': 9, 'status': 'active'});
      expect(ledger.goals.get('remote1').name, 'R');
      ledger.goals.deleteRaw('remote1');
      expect(ledger.goals.find('remote1'), isNull);
    });
  });

  group('wealth metrics', () {
    test('disposable = liquid − locked − fixed due; payday inferred from salary; level from runway; savings rate; income lines; net worth counts debt', () {
      // 工资 6/10、7/10、8/10 到账 → 推出发薪日 10 号
      for (final m in ['06', '07', '08']) {
        add(income(1500000, '2026-$m-10'));
        add(expense(400000, '2026-$m-15'));
        add(expense(300000, '2026-$m-20', cat: 'housing'));
      }
      add(income(50000, '2026-09-05', cat: 'parttime'));
      add(income(1500000, '2026-09-10'));
      add(expense(20000, '2026-09-20'));
      ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 220000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-10-01');
      ledger.createAccount(id: 'card', name: '信用卡', type: AccountType.creditCard, currency: 'CNY', initialBalanceMinor: -80000);
      ledger.createAccount(id: 'usd', name: '美元', type: AccountType.bank, currency: 'USD', initialBalanceMinor: 100);
      final g = ledger.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 699900);
      add(ledger.goals.depositPayload(g, 100000, fromAccountId: wechat.id));

      final m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.payday, '2026-10-10');
      expect(m.paydaySource, 'inferred');
      expect(m.daysToPayday, 20);
      final liquid = ledger.balance('wechat').minor + ledger.balance('bank').minor + 100000;
      expect(m.liquidMinor, liquid);
      expect(m.lockedMinor, 100000);
      expect(m.fixedDueMinor, 220000); // 10/1 房租在发薪日前
      expect(m.cardOwedMinor, 80000); // 信用卡欠的：刷了就从可花的里扣
      expect(m.disposableMinor, liquid - 100000 - 220000 - 80000);
      expect(m.spentTodayMinor, 20000);
      // 可花的来自余额，今天的 200 已经扣过了：今天还能花 = 可花的 ÷ 天数，不再减一次（以前减两次，可花 150 却显示 0）
      expect(m.dailyAllowanceMinor, ((liquid - 100000 - 220000 - 80000) / 20).floor());
      expect(m.monthsOfData, 3);
      expect(m.spendBasis, SpendBasis.history);
      expect(m.monthlySpendAvgMinor, 700000);
      expect(m.runwayMonths, closeTo(liquid / 700000, 1e-9));
      expect(m.level!.name, WealthLevel.of(liquid / 700000).name);
      expect(m.monthIncomeMinor, 1550000);
      expect(m.incomeByLine[IncomeLine.main], 1500000);
      expect(m.incomeByLine[IncomeLine.side], 50000);
      expect(m.savingsRate, closeTo((1550000 - 20000) / 1550000, 1e-9));
      expect(m.netWorthMinor, liquid - 80000);
      expect(m.assetsMinor, liquid);
      expect(m.debt.cardMinor, 80000);
      expect(m.debt.loanMinor, 0);
      expect(m.excludedForeign.single.id, 'usd');

      // 画像填了发薪日就按画像
      ledger.profile.payday = 25;
      expect(Wealth(ledger).nextPayday(today: '2026-09-20'), ('2026-09-25', 'profile'));
      expect(Wealth(ledger).nextPayday(today: '2026-09-26').$1, '2026-10-25');
      ledger.profile.payday = null;
      // 没有收入记录：月底
      final fresh = Ledger(openLedgerDatabaseInMemory())..seedDefaultCategories();
      expect(Wealth(fresh).nextPayday(today: '2026-09-20'), ('2026-09-30', 'month_end'));
      final fm = Wealth(fresh).compute(today: '2026-09-20');
      expect(fm.level, isNull);
      expect(fm.spendBasis, SpendBasis.none);
    });

    test('可花的永远 ≤ 余额：透支成负数的钱包要减，贷款 / 投资 / 信用卡不进「余额」', () {
      // 真机：支付宝没填期初、自动记账记了一笔支出 → 支付宝 −189；还有一笔网贷 −1392、一个投资账户。
      // 旧口径：首页余额 = 所有账户相加（含贷款负数 / 投资），可花的只从「正余额的现金类账户」算起 → 可花的比余额还多
      ledger.createAccount(id: 'alipay', name: '支付宝', type: AccountType.eWallet, currency: 'CNY');
      add(expense(18911, '2026-09-19', account: 'alipay'));
      ledger.createAccount(id: 'loan', name: '网贷', type: AccountType.payable, currency: 'CNY', initialBalanceMinor: -139246);
      ledger.createAccount(id: 'fund', name: '基金', type: AccountType.investment, currency: 'CNY', initialBalanceMinor: 50000);
      final m = Wealth(ledger).compute(today: '2026-09-20');
      final cash = ledger.balance('wechat').minor + ledger.balance('bank').minor - 18911;
      expect(m.cashMinor, cash);
      expect(Wealth.cashOnHand(ledger), cash);
      expect(m.liquidMinor, cash);
      expect(m.disposableMinor, lessThanOrEqualTo(m.cashMinor));
      expect(m.disposableMinor, cash);
      expect(m.netWorthMinor, cash - 139246 + 50000);

      // 手头的钱整体透支：流动资产按 0 算（生存月数 / 应急金不出现负数），可花的照实是负的
      final poor = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 9, 20, 4))..seedDefaultCategories();
      poor.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: -5000);
      poor.createAccount(id: 'b', name: '银行卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 2000);
      final pm = Wealth(poor).compute(today: '2026-09-20');
      expect(pm.cashMinor, -3000);
      expect(pm.liquidMinor, 0);
      expect(pm.disposableMinor, -3000);
      expect(pm.dailyAllowanceMinor, 0);
    });

    test('称号不用等一个月：近 31 天收入（月光）→ 本月按天外推 → 周期账单 → 手填，依次兜底', () {
      // 只有本月两笔支出、没收入：9/5、9/12 各花 300；今天 9/20 → 外推 600 × 30 / 20 = 900/月
      add(expense(30000, '2026-09-05'));
      add(expense(30000, '2026-09-12'));
      var m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.monthsOfData, 0);
      expect(m.spendBasis, SpendBasis.thisMonth);
      expect(m.monthlySpendAvgMinor, (60000 * 30 / 20).round());
      expect(m.level, isNotNull);
      expect(m.runwayMonths, closeTo(m.liquidMinor / 90000, 1e-9));
      // 周期账单比外推大：按周期账单合计（房租 2200 + 还贷 3000 = 5200）
      ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 220000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-10-01');
      final loan = ledger.debts.add(name: '车贷', kind: DebtKind.car, owedMinor: 6000000, monthlyMinor: 300000, day: 15, fromAccountId: 'bank', today: '2026-09-20');
      m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.spendBasis, SpendBasis.thisMonth);
      expect(m.monthlySpendAvgMinor, 520000);
      expect(m.repaymentMonthlyMinor, 300000);
      expect(m.debt.loanMinor, 6000000);
      expect(m.debt.monthsLeft, 20);
      expect(m.netWorthMinor, m.assetsMinor - 6000000);
      expect(m.inDebt, isTrue);
      // 有了工资：先按收入当月支出（月光算法），几笔支出外推出的「够花一百个月」不算数
      add(income(1000000, '2026-09-02'));
      m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.spendBasis, SpendBasis.income);
      expect(m.monthlySpendAvgMinor, 1000000);
      // 发薪日 10/2（从 9/2 的工资推的）之前要还的：房租 10/1；车贷下次 10/15 不在窗口内
      expect(m.payday, '2026-10-02');
      expect(loan.repayment!.nextDue, '2026-10-15');
      expect(m.fixedDueMinor, 220000);
      // 手填月支出压过一切
      ledger.profile.monthlyCostMinor = 800000;
      m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.spendBasis, SpendBasis.manual);
      expect(m.monthlySpendAvgMinor, 800000);
      ledger.profile.monthlyCostMinor = null;
      // 一笔支出都没有、只有工资：同样按收入估；今天还能花 = 可花的 ÷ 天数
      final fresh = Ledger(openLedgerDatabaseInMemory())..seedDefaultCategories();
      fresh.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
      final d = fresh.propose([DraftInput(payload: {'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'salary', 'occurred_at': '2026-09-10T09:00:00+08:00'})], source: Source.manual, actor: Actor.user).single;
      fresh.commit(d.id);
      final fm = Wealth(fresh).compute(today: '2026-09-20');
      expect(fm.spendBasis, SpendBasis.income);
      expect(fm.monthlySpendAvgMinor, 1000000);
      expect(fm.level!.title, '温饱户'); // 1 万 ÷ 1 万 = 1 个月
      expect(fm.dailyAllowanceMinor, (1000000 / fm.daysToPayday).floor());
    });

    test('负债三件套：账户 + 周期转账 + 还清目标；还一期后余额 / 进度 / 每月合计都跟着走；等级口径把还贷算进月支出', () {
      final setup = ledger.debts.add(name: '房贷', kind: DebtKind.mortgage, owedMinor: 50000000, monthlyMinor: 400000, day: 10, fromAccountId: 'bank', today: '2026-09-20');
      expect(setup.account.type, AccountType.payable);
      expect(ledger.balance(setup.account.id).minor, -50000000);
      expect(setup.repayment!.template['type'], 'transfer');
      expect(setup.repayment!.nextDue, '2026-10-10');
      expect(setup.goal.kind, GoalKind.payoff);
      expect(setup.goal.targetMinor, 50000000);
      final card = ledger.createAccount(id: 'cc', name: '信用卡', type: AccountType.creditCard, currency: 'CNY', initialBalanceMinor: -30000);
      var list = ledger.debts.list();
      expect(list.map((d) => d.account.id).toList(), [setup.account.id, card.id]);
      expect(list.first.kind, DebtKind.mortgage);
      expect(list.first.monthlyMinor, 400000);
      expect(list.first.monthsLeft, 125);
      var t = ledger.debts.totals();
      expect(t.loanMinor, 50000000);
      expect(t.cardMinor, 30000);
      expect(t.monthlyMinor, 400000);
      expect(t.count, 2);
      // 还一期：转账 4000 到房贷账户
      add({'type': 'transfer', 'amount_minor': 400000, 'currency': 'CNY', 'account_id': 'bank', 'to_account_id': setup.account.id, 'occurred_at': '2026-08-10T09:00:00+08:00'});
      list = ledger.debts.list();
      expect(list.first.owedMinor, 49600000);
      expect(list.first.paidMinor, 400000);
      expect(ledger.goals.progress(setup.goal, today: '2026-09-20').savedMinor, 400000);
      // 上个月的还贷算进月支出：8 月流出 = 4000（没有别的支出）
      add(expense(100000, '2026-08-20'));
      final m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.spendBasis, SpendBasis.history);
      expect(m.monthlySpendAvgMinor, 500000);
      // 换还款额：旧的停掉，新的一条
      ledger.debts.setRepayment(setup.account.id, monthlyMinor: 450000, day: 12, fromAccountId: 'bank', today: '2026-09-20');
      t = ledger.debts.totals();
      expect(t.monthlyMinor, 450000);
      expect(ledger.recurring.list().where((r) => r.template['to_account_id'] == setup.account.id).length, 1);
      // 每月几号从今天起算：今天 20 号、要 12 号 → 下个月
      expect(ledger.recurring.list().firstWhere((r) => r.template['to_account_id'] == setup.account.id).nextDue, '2026-10-12');
    });

    test('删负债：没还过款 → 账户 / 还款提醒（含停掉的）/ 还清目标全真删；还过款 → 账户归档保历史、另外两件删；发薪账户和记忆里的引用清掉', () {
      // 没还过款的：真删
      final s1 = ledger.debts.add(name: '网贷', kind: DebtKind.online, owedMinor: 500000, monthlyMinor: 100000, day: 5, fromAccountId: 'bank', today: '2026-09-20');
      ledger.debts.setRepayment(s1.account.id, monthlyMinor: 120000, day: 6, fromAccountId: 'bank', today: '2026-09-20'); // 旧的那条停掉，不是删
      expect(ledger.recurring.list(activeOnly: false).where((r) => r.template['to_account_id'] == s1.account.id).length, 2);
      ledger.profile.salaryAccountId = s1.account.id;
      var r = ledger.debts.remove(s1.account.id);
      expect(r.accountDeleted, isTrue);
      expect(r.postingCount, 0);
      expect(r.repaymentsRemoved, 2);
      expect(r.goalsRemoved, 1);
      expect(ledger.account(s1.account.id), isNull);
      expect(ledger.recurring.list(activeOnly: false).where((r) => r.template['to_account_id'] == s1.account.id), isEmpty);
      expect(ledger.goals.find(s1.goal.id), isNull);
      expect(ledger.profile.salaryAccountId, isNull);
      expect(ledger.debts.list().where((d) => d.account.id == s1.account.id), isEmpty);
      // 变更日志里是三条 deleted，另一台设备同步后一样没了
      final deleted = ledger.changes.pending().where((c) => c.deleted).map((c) => c.entity).toList();
      expect(deleted, containsAll(['account', 'recurring', 'goal']));

      // 还过一期的：账户只归档
      final s2 = ledger.debts.add(name: '车贷', kind: DebtKind.car, owedMinor: 6000000, monthlyMinor: 300000, day: 15, fromAccountId: 'bank', today: '2026-09-20');
      add({'type': 'transfer', 'amount_minor': 300000, 'currency': 'CNY', 'account_id': 'bank', 'to_account_id': s2.account.id, 'occurred_at': '2026-09-15T09:00:00+08:00'});
      expect(() => ledger.deleteAccount(s2.account.id), throwsA(isA<InvalidStateException>()));
      r = ledger.debts.remove(s2.account.id);
      expect(r.accountDeleted, isFalse);
      expect(r.postingCount, 1); // 转账两条 posting，落在这个账户上的一条
      expect(ledger.account(s2.account.id)!.isArchived, isTrue);
      expect(ledger.goals.find(s2.goal.id), isNull);
      expect(ledger.recurring.list(activeOnly: false).where((r) => r.template['to_account_id'] == s2.account.id), isEmpty);
      expect(ledger.debts.list().where((d) => d.account.id == s2.account.id), isEmpty); // 负债页不再列
      expect(ledger.listTransactions(accountId: s2.account.id, limit: 10).length, 1); // 还款流水没被动
      // 不是负债账户不让走这条路
      expect(() => ledger.debts.remove('bank'), throwsA(isA<InvalidStateException>()));
      // 目标 / 周期项还引用着的账户不能删（先清引用）
      final s3 = ledger.debts.add(name: '借款', kind: DebtKind.loan, owedMinor: 100000, monthlyMinor: 50000, day: 1, fromAccountId: 'bank', today: '2026-09-20');
      expect(() => ledger.deleteAccount(s3.account.id), throwsA(predicate((e) => e is InvalidStateException && '$e'.contains('goals'))));
    });

    test('同步：对方删了账户，本机没它的记录就跟着删，有记录就退成归档', () {
      final l2 = Ledger(openLedgerDatabaseInMemory())..seedDefaultCategories();
      final s = ledger.debts.add(name: '网贷', kind: DebtKind.online, owedMinor: 500000, today: '2026-09-20');
      final pushed = ledger.changes.pending();
      for (final c in pushed) {
        l2.applyRemoteChange(c, fromDevice: 'dev1');
      }
      ledger.changes.markPushed(pushed.map((c) => c.seq));
      expect(l2.account(s.account.id), isNotNull);
      // l2 上对它记了一笔还款（还没同步回去），dev1 那边把负债删了
      l2.createAccount(id: 'bank2', name: '卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
      final d = l2.propose([DraftInput(payload: {'type': 'transfer', 'amount_minor': 10000, 'currency': 'CNY', 'account_id': 'bank2', 'to_account_id': s.account.id, 'occurred_at': '2026-09-21T09:00:00+08:00'})], source: Source.manual, actor: Actor.user).single;
      l2.commit(d.id);
      // 干净的第三台先拿到建账那批
      final l3 = Ledger(openLedgerDatabaseInMemory())..seedDefaultCategories();
      for (final c in pushed) {
        l3.applyRemoteChange(c, fromDevice: 'dev1');
      }
      ledger.debts.remove(s.account.id);
      for (final c in ledger.changes.pending()) {
        expect(l2.applyRemoteChange(c, fromDevice: 'dev1'), 'applied');
        expect(l3.applyRemoteChange(c, fromDevice: 'dev1'), 'applied');
      }
      expect(l2.account(s.account.id)!.isArchived, isTrue); // 有记录：归档
      expect(l2.goals.find(s.goal.id), isNull);
      expect(l3.account(s.account.id), isNull); // 没记录：真删
      expect(l3.goals.find(s.goal.id), isNull);
    });

    test('每档等级都有称号；最穷是贫困户，每档不重名，档位边界落在高一档', () {
      expect(WealthLevel.of(0).title, '贫困户');
      expect(WealthLevel.of(0.49).title, '贫困户');
      expect(WealthLevel.of(0.5).title, '月光族');
      expect(WealthLevel.of(1).title, '温饱户');
      expect(WealthLevel.of(3).title, '小康');
      expect(WealthLevel.of(6).title, '中产');
      expect(WealthLevel.of(12).title, '人上人');
      expect(WealthLevel.of(999).title, '人上人');
      expect(WealthLevel.levels.map((l) => l.title).toSet().length, WealthLevel.levels.length);
      expect(WealthLevel.levels.every((l) => l.title.isNotEmpty && l.name.isNotEmpty), isTrue);
    });

    test('负翁档：净资产为负按欠款分档，边界落在重一档；再还多少降一档；还清回到等级称号', () {
      expect(DebtTier.of(1).title, '小负翁');
      expect(DebtTier.of(999999).title, '小负翁');
      expect(DebtTier.of(1000000).title, '负翁');
      expect(DebtTier.of(10000000).title, '大负翁');
      expect(DebtTier.of(100000000).title, '百万负翁');
      expect(DebtTier.of(1000000000).title, '千万负翁');
      expect(DebtTier.of(1 << 40).title, '千万负翁');
      expect(DebtTier.tiers.map((t) => t.title).toSet().length, DebtTier.tiers.length);
      expect(DebtTier.tiers.first.lighter, isNull);
      expect(DebtTier.tiers.last.lighter!.title, '百万负翁');

      // 有工资 → 有等级（资产 5 万初始 + 1 万工资）；再背 8 万车贷 → 净资产 −2 万 → 称号换成「负翁」，等级名不变
      add(income(1000000, '2026-09-02'));
      var m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.inDebt, isFalse);
      expect(m.debtTier, isNull);
      expect(m.title, m.level!.title);
      expect(m.toLighterDebtTierMinor, isNull);
      ledger.debts.add(name: '车贷', kind: DebtKind.car, owedMinor: 8000000, monthlyMinor: 300000, day: 15, fromAccountId: 'bank', today: '2026-09-20');
      m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.inDebt, isTrue);
      expect(m.netWorthMinor, -2000000);
      expect(m.debtTier!.title, '负翁');
      expect(m.title, '负翁');
      expect(m.level, isNotNull); // 等级还在：够花几个月照算
      // 降到「小负翁」= 欠款降到 1 万以下：再还 (欠款 − 1 万 + 1 分)
      expect(m.toLighterDebtTierMinor, -m.netWorthMinor - 1000000 + 1);
      expect(DebtTier.of(-m.netWorthMinor - m.toLighterDebtTierMinor!).title, '小负翁');
      // 再进 1.5 万 → 净资产 −5000 → 最轻一档「小负翁」：再还多少 = 全部欠款（净资产转正）
      add(income(1500000, '2026-09-03'));
      m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.netWorthMinor, -500000);
      expect(m.debtTier!.title, '小负翁');
      expect(m.toLighterDebtTierMinor, 500000);
      // 转正：称号回到等级那套
      add(income(500000, '2026-09-04'));
      m = Wealth(ledger).compute(today: '2026-09-20');
      expect(m.inDebt, isFalse);
      expect(m.title, m.level!.title);
    });
  });

  group('tasks', () {
    test('progress and settlement for each kind; templates come from last week; reward deposit', () {
      ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 29, 4)); // 这个用例要记到 9/25，时钟往后拨
      // 上周 9/14–9/20：餐饮 200 + 外卖 3 次
      add(expense(8000, '2026-09-14', merchant: '美团外卖'));
      add(expense(6000, '2026-09-15', merchant: '饿了么'));
      add(expense(6000, '2026-09-17', merchant: '美团'));
      add(expense(30000, '2026-09-18', cat: 'shopping'));
      final tpl = ledger.tasks.templates(today: '2026-09-21');
      expect(tpl.any((t) => t.kind == TaskKind.countCap), isTrue);
      expect(tpl.any((t) => t.kind == TaskKind.noSpendDays), isTrue);
      expect(tpl.where((t) => t.kind == TaskKind.categoryCap).any((t) => t.params['category_id'] == 'shopping'), isTrue);

      final week = TaskStore.weekOf('2026-09-23');
      expect(week, '2026-09-21');
      final cap = ledger.tasks.create(week: week, kind: TaskKind.categoryCap, params: {'category_id': 'food', 'cap_minor': 30000}, title: '本周餐饮不超过 300');
      final cnt = ledger.tasks.create(week: week, kind: TaskKind.countCap, params: {'keywords': ['美团', '饿了么'], 'max': 2}, title: '外卖 ≤ 2');
      final nsd = ledger.tasks.create(week: week, kind: TaskKind.noSpendDays, params: {'min_days': 2}, title: '2 个无消费日');
      final g = ledger.goals.create(kind: GoalKind.wish, name: 'G', targetMinor: 100000);
      final dep = ledger.tasks.create(week: week, kind: TaskKind.deposit, params: {'goal_id': g.id, 'min_minor': 5000}, title: '存 50', rewardGoalId: g.id, rewardMinor: 1000);

      add(expense(20000, '2026-09-22', merchant: '美团外卖'));
      add(expense(15000, '2026-09-23'));
      ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-09-24');
      final rentDraft = ledger.recurring.generateDue(today: '2026-09-24', tzOffsetMinutes: 480).single;
      ledger.commit(rentDraft.id); // 周期账单不破无消费日
      add(ledger.goalsDeposit(g, 6000, from: wechat.id, date: '2026-09-25'));

      expect(ledger.tasks.progress(cap, today: '2026-09-23').onTrack, isFalse); // 350 > 300
      expect(ledger.tasks.progress(cnt, today: '2026-09-23').current, 1);
      final n = ledger.tasks.progress(nsd, today: '2026-09-25');
      expect(n.current, 2); // 21、24（房租不算）
      expect(n.achieved, isTrue);
      expect(ledger.tasks.progress(dep, today: '2026-09-25').achieved, isTrue);

      expect(ledger.tasks.settle(week, today: '2026-09-27'), isEmpty); // 周还没过完
      final settled = ledger.tasks.settle(week, today: '2026-09-28');
      expect(settled.length, 4);
      final byId = {for (final t in settled) t.id: t.result};
      expect(byId[cap.id], TaskResult.missed);
      expect(byId[cnt.id], TaskResult.done);
      expect(byId[nsd.id], TaskResult.done);
      expect(byId[dep.id], TaskResult.done);
      expect(settled.firstWhere((t) => t.id == cap.id).evidence!['current'], 35000);
      expect(ledger.tasks.settle(week, today: '2026-09-29'), isEmpty); // 不重复结算
      expect(ledger.auditLog().where((e) => e.action == 'task.settle').length, 4);
    });
  });

  group('achievements', () {
    test('unlock once with evidence; sync keeps the earliest', () {
      final g = ledger.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 100000);
      add(ledger.goals.depositPayload(g, 30000, fromAccountId: wechat.id));
      add(income(1000, '2026-09-01', cat: 'investment_income'));
      AchievementContext ctx() {
        final m = Wealth(ledger).compute(today: '2026-09-20');
        return AchievementContext(ledger: ledger, metrics: m, today: '2026-09-20', goals: [for (final x in ledger.goals.list()) ledger.goals.progress(x, today: '2026-09-20', liquidMinor: m.liquidMinor, netWorthMinor: m.netWorthMinor)], settledTasks: const []);
      }

      final first = ledger.achievements.check(ctx());
      final keys = first.map((a) => a.key).toSet();
      expect(keys, containsAll(['goal.first', 'goal.p10', 'goal.p25', 'income.passive']));
      expect(keys, isNot(contains('goal.p50')));
      expect(first.firstWhere((a) => a.key == 'goal.p25').evidence!['goal'], '换手机');
      expect(ledger.achievements.check(ctx()), isEmpty); // 不重复
      add(ledger.goals.depositPayload(g, 30000, fromAccountId: wechat.id));
      expect(ledger.achievements.check(ctx()).map((a) => a.key), ['goal.p50']);
      ledger.achievements.upsertRaw({'key': 'goal.p50', 'unlocked_at': 1, 'evidence': {'goal': 'x'}});
      expect(ledger.achievements.list().firstWhere((a) => a.key == 'goal.p50').unlockedAt, 1);
      ledger.achievements.upsertRaw({'key': 'goal.p50', 'unlocked_at': 99});
      expect(ledger.achievements.list().firstWhere((a) => a.key == 'goal.p50').unlockedAt, 1);
    });

    test('supporter: profile kv drives the achievement; first record time follows the ledger', () {
      expect(ledger.firstRecordedAtMs(), isNull);
      add(income(1000, '2026-09-01', cat: 'investment_income'));
      expect(ledger.firstRecordedAtMs(), isNotNull);
      AchievementContext ctx() {
        final m = Wealth(ledger).compute(today: '2026-09-20');
        return AchievementContext(ledger: ledger, metrics: m, today: '2026-09-20', goals: const [], settledTasks: const []);
      }

      expect(ledger.achievements.check(ctx()).map((a) => a.key), isNot(contains('support.yujian')));
      expect(ledger.profile.supporterSince, isNull);
      ledger.profile.supportSnoozeUntil = '2026-10-21';
      expect(ledger.profile.supportSnoozeUntil, '2026-10-21');
      ledger.profile.supporterSince = '2026-09-21';
      final got = ledger.achievements.check(ctx()).where((a) => a.key == 'support.yujian').single;
      expect(got.evidence!['since'], '2026-09-21');
      ledger.profile.supporterSince = '';
      expect(ledger.profile.supporterSince, isNull); // 空串当没设
    });
  });

  group('portability + sync', () {
    test('export/restore round-trips goals, tasks, achievements, profile and the vault account', () {
      final g = ledger.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 100000);
      add(ledger.goals.depositPayload(g, 30000, fromAccountId: wechat.id));
      ledger.tasks.create(week: '2026-09-14', kind: TaskKind.noSpendDays, params: {'min_days': 2}, title: 't');
      ledger.profile.payday = 10;
      ledger.achievements.upsertRaw({'key': 'goal.first', 'unlocked_at': 5});
      final j = exportJson(ledger);
      expect((j['goals'] as List).length, 1);
      expect((j['profile'] as Map)['payday'], '10');
      final db2 = openLedgerDatabaseInMemory();
      final l2 = Ledger(db2);
      restoreFromJson(l2, j);
      expect(l2.goals.get(g.id).name, '换手机');
      expect(l2.goals.savedMinor(l2.goals.get(g.id)), 30000);
      expect(l2.tasks.list().single.title, 't');
      expect(l2.profile.payday, 10);
      expect(l2.achievements.list().single.key, 'goal.first');
      expect(l2.changes.pending().any((c) => c.entity == 'goal'), isTrue);
      // 远端变更应用
      final l3 = Ledger(openLedgerDatabaseInMemory())..seedDefaultCategories();
      for (final c in l2.changes.pending(limit: 1000)) {
        l3.applyRemoteChange(c, fromDevice: 'dev2');
      }
      expect(l3.goals.get(g.id).name, '换手机');
      expect(l3.profile.payday, 10);
      expect(l3.getAccount(g.vaultAccountId!).type, AccountType.vault);
    });
  });
}

extension on Ledger {
  Map<String, Object?> goalsDeposit(Goal g, int minor, {required String from, required String date}) => {...goals.depositPayload(g, minor, fromAccountId: from), 'occurred_at': '${date}T10:00:00+08:00'};
}
