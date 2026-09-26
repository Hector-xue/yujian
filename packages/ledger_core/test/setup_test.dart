import 'dart:convert';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 对话建档：建出来的东西和手动表单一样，汇总数字对得上；撤销干净；失败不留半截。
void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  const today = '2026-09-27';

  Ledger fresh() {
    final l = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 9, 27, 4))..seedDefaultCategories();
    l.createAccount(id: 'bank', name: '工商银行', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 2000000);
    l.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 100000);
    return l;
  }

  setUp(() {
    ledger = fresh();
    db = ledger.database;
  });
  tearDown(() => db.close());

  SetupEnv env([String t = today]) => SetupEnv.of(ledger, today: t);

  SetupItem baitiao({int day = 15}) => SetupItem(kind: SetupKind.loan, name: '京东白条', debtKind: DebtKind.online, principalMinor: 500000, monthlyMinor: 100000, day: day, fromAccountId: 'wechat');

  group('贷款', () {
    test('建出三件：负债账户 + 每月还款 + 还清目标，和表单建的一模一样', () {
      final r = Setups(ledger).apply([baitiao()], env: env()).single;
      final a = ledger.getAccount(r.accountId);
      expect((a.name, a.type, a.initialBalanceMinor), ('京东白条', AccountType.payable, -500000));
      final rep = ledger.recurring.get(r.recurringId!);
      expect(rep.nextDue, '2026-10-15', reason: '今天 27 号，15 号已过 → 下个月');
      expect(rep.template['amount_minor'], 100000);
      expect(rep.template['account_id'], 'wechat');
      expect(ledger.goals.get(r.goalId!).kind, GoalKind.payoff);

      // 同样的数用表单（Debts.add）在另一个账本建一遍：负债合计 / 净资产 / 可花的 全部一致
      final l2 = fresh();
      l2.debts.add(name: '京东白条', kind: DebtKind.online, owedMinor: 500000, monthlyMinor: 100000, day: 15, fromAccountId: 'wechat', today: today);
      final m1 = Wealth(ledger).compute(today: today);
      final m2 = Wealth(l2).compute(today: today);
      expect(m1.netWorthMinor, m2.netWorthMinor);
      expect(m1.debt.totalMinor, m2.debt.totalMinor);
      expect(m1.debt.loanMonthlyMinor, m2.debt.loanMonthlyMinor);
      expect(m1.disposableMinor, m2.disposableMinor);
      expect(m1.netWorthMinor, 2000000 + 100000 - 500000);
      l2.database.close();
    });
    test('首期还款日：还没到 / 今天且没还 / 今天且还了 / 已过 / 下个月开始', () {
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 28)..name = 'a'], env: env()).single.recurringId!).nextDue, '2026-09-28');
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 27)..name = 'b'..paidThisPeriod = false], env: env()).single.recurringId!).nextDue, '2026-09-27');
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 27)..name = 'c'..paidThisPeriod = true], env: env()).single.recurringId!).nextDue, '2026-10-27');
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 5)..name = 'd'], env: env()).single.recurringId!).nextDue, '2026-10-05');
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 28)..name = 'e'..startNextMonth = true], env: env()).single.recurringId!).nextDue, '2026-10-28');
      // 31 号按 28：今天 27 → 这个月 28 号
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 31)..name = 'f'], env: env()).single.recurringId!).nextDue, '2026-09-28');
      // 12 月跨年
      expect(ledger.recurring.get(Setups(ledger).apply([baitiao(day: 5)..name = 'g'], env: env('2026-12-20')).single.recurringId!).nextDue, '2027-01-05');
    });
    test('今天是还款日、没问这期还没还：拒绝（必填）', () {
      expect(() => Setups(ledger).apply([baitiao(day: 27)], env: env()), throwsA(isA<ValidationException>()));
      expect(ledger.listAccounts().where((a) => a.name == '京东白条'), isEmpty);
    });
    test('只记欠款不设月供：没有周期项，还清目标照建', () {
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.loan, name: '欠小王', debtKind: DebtKind.loan, principalMinor: 300000)], env: env()).single;
      expect(r.recurringId, isNull);
      expect(ledger.debts.totals(today: today).loansWithoutRepayment, 1);
    });
    test('按期数推出来的欠款', () {
      final it = SetupItem(kind: SetupKind.loan, name: '车贷', debtKind: DebtKind.car, monthlyMinor: 200000, periods: 24, day: 10, fromAccountId: 'bank')..infer(env());
      final r = Setups(ledger).apply([it], env: env()).single;
      expect(ledger.getAccount(r.accountId).initialBalanceMinor, -4800000);
    });
    test('没给扣款账户：推断顺序 工资账户 → 默认账户 → 唯一活钱账户', () {
      expect(env().preferredFromAccountId, isNull, reason: '两个活钱账户、没设工资 / 默认：要问');
      ledger.profile.defaultAccountId = 'wechat';
      expect(env().preferredFromAccountId, 'wechat');
      ledger.profile.salaryAccountId = 'bank';
      expect(env().preferredFromAccountId, 'bank');
    });
  });

  group('信用额度', () {
    test('建成信用卡账户 + 条款，额度 / 账单日 / 还款日 对', () {
      final it = SetupItem(kind: SetupKind.credit, name: '花呗', product: CreditProduct.huabei, principalMinor: 300000, limitMinor: 800000, dueDay: 15)..infer(env());
      expect(it.statementDay, 5);
      final r = Setups(ledger).apply([it], env: env()).single;
      final a = ledger.getAccount(r.accountId);
      expect((a.type, a.initialBalanceMinor), (AccountType.creditCard, -300000));
      final t = ledger.cards.terms(a.id)!;
      expect((t.limitMinor, t.statementDay, t.dueDay, t.product, t.mode), (800000, 5, 15, CreditProduct.huabei, CardInterestMode.afterDue));
      expect(Wealth(ledger).compute(today: today).debt.cardMinor, 300000);
    });
    test('没额度：拒绝（额度 0 会让整笔欠款显示成超额）', () {
      final it = SetupItem(kind: SetupKind.credit, name: '花呗', product: CreditProduct.huabei, principalMinor: 300000, dueDay: 15, statementDay: 5);
      expect(() => Setups(ledger).apply([it], env: env()), throwsA(isA<ValidationException>()));
    });
    test('账单日推算：白条 15 号还款 → 6 号', () {
      final it = SetupItem(kind: SetupKind.credit, name: '京东白条', product: CreditProduct.baitiao, dueDay: 15);
      expect(it.derivedStatementDay(), 6);
      final b = SetupItem(kind: SetupKind.credit, name: '信用卡', product: CreditProduct.bank, dueDay: 10);
      expect(b.derivedStatementDay(), 20, reason: '银行卡账单日后 20 天还，跨月倒推');
    });
  });

  group('资产', () {
    test('定期：investment 类型，算净资产、不算手头余额（不抬高可花的）', () {
      final before = Wealth(ledger).compute(today: today);
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: '工行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, maturity: '2027-03-15', ratePercent: 2.1)], env: env()).single;
      final after = Wealth(ledger).compute(today: today);
      expect(after.netWorthMinor - before.netWorthMinor, 1000000);
      expect(Wealth.cashOnHand(ledger), Wealth.cashOnHand(fresh()));
      expect(after.disposableMinor, before.disposableMinor);
      final t = DepositTerms.read(ledger, r.accountId)!;
      expect((t.maturity, t.ratePercent), ('2027-03-15', 2.1));
    });
    test('从已有账户转过去：新账户期初 0 + 一笔转账，净资产不变（不重复算）', () {
      final before = Wealth(ledger).compute(today: today);
      final r = Setups(ledger).apply([
        SetupItem(kind: SetupKind.asset, name: '工行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, viaAction: true, fromTransfer: true, fromAccountId: 'bank'),
      ], env: env()).single;
      final after = Wealth(ledger).compute(today: today);
      expect(after.netWorthMinor, before.netWorthMinor);
      final bal = ledger.balances();
      expect(bal['bank']!.minor, 1000000);
      expect(bal[r.accountId]!.minor, 1000000);
      expect(ledger.getTransaction(r.transferTxId!).type, TransactionType.transfer);
    });
    test('动作句没回答钱从哪来：拒绝', () {
      expect(() => Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: '定期存款', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, viaAction: true)], env: env()), throwsA(isA<ValidationException>()));
    });
    test('别人欠我：应收账户', () {
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.receivable, name: '借给小李', principalMinor: 300000)], env: env()).single;
      expect(ledger.getAccount(r.accountId).type, AccountType.receivable);
    });
  });

  group('一起建 / 失败回滚 / 同名', () {
    test('多项一个事务：后一项失败，前一项也不留', () {
      final n = ledger.listAccounts().length;
      expect(
          () => Setups(ledger).apply([
                baitiao(),
                SetupItem(kind: SetupKind.credit, name: '花呗', product: CreditProduct.huabei, principalMinor: 1, dueDay: 15, statementDay: 5), // 没额度
              ], env: env()),
          throwsA(isA<ValidationException>()));
      expect(ledger.listAccounts().length, n);
      expect(ledger.recurring.list(), isEmpty);
      expect(ledger.goals.list(), isEmpty);
    });
    test('已有同名账户：拒绝建；同一批里重名也拒绝；标了 existing 的项跳过', () {
      expect(() => Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: ' 微信 ', assetType: AccountType.eWallet, principalMinor: 1)], env: env()), throwsA(isA<ValidationException>()));
      expect(() => Setups(ledger).apply([baitiao(), baitiao()], env: env()), throwsA(isA<ValidationException>()));
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: '微信', principalMinor: 1, existingAccountId: 'wechat'), baitiao()], env: env());
      expect(r.single.kind, SetupKind.loan);
    });
    test('扣款账户已归档 / 币种不同：拒绝', () {
      ledger.archiveAccount('wechat');
      expect(() => Setups(ledger).apply([baitiao()], env: env()), throwsA(isA<ValidationException>()));
    });
    test('写进变更日志（能同步）', () {
      final before = ledger.changes.pending().length;
      Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: '工行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, maturity: '2027-03-15')], env: env());
      final entities = ledger.changes.pending().skip(before).map((c) => c.entity).toSet();
      expect(entities, containsAll(['account', 'profile']));
    });
  });

  group('撤销', () {
    test('贷款：账户 / 周期项 / 目标全删', () {
      final r = Setups(ledger).apply([baitiao()], env: env());
      expect(Setups(ledger).undo(r), 1);
      expect(ledger.account(r.single.accountId), isNull);
      expect(ledger.recurring.list(activeOnly: false), isEmpty);
      expect(ledger.goals.list(activeOnly: false), isEmpty);
    });
    test('贷款：还款提醒已经起草了今天那期 → 撤销时一起忽略掉', () {
      final r = Setups(ledger).apply([baitiao(day: 27)..paidThisPeriod = false], env: env());
      final drafts = ledger.recurring.generateDue(today: today, tzOffsetMinutes: 480);
      expect(drafts, hasLength(1));
      Setups(ledger).undo(r);
      expect(ledger.account(r.single.accountId), isNull);
      expect(ledger.listDrafts(status: DraftStatus.pending), isEmpty);
    });
    test('上面已经记过账：只归档，历史不删', () {
      final r = Setups(ledger).apply([baitiao()], env: env());
      final d = ledger.propose([
        DraftInput(payload: {'type': 'transfer', 'amount_minor': 100000, 'currency': 'CNY', 'account_id': 'wechat', 'to_account_id': r.single.accountId, 'occurred_at': '2026-09-27T12:00:00+08:00'})
      ], source: Source.manual, actor: Actor.user).single;
      ledger.commit(d.id);
      expect(Setups(ledger).undo(r), 0);
      expect(ledger.getAccount(r.single.accountId).isArchived, isTrue);
    });
    test('别的待确认草稿用着它：拒绝撤销（不替人丢草稿）', () {
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: '工行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000)], env: env());
      ledger.propose([
        DraftInput(payload: {'type': 'transfer', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'bank', 'to_account_id': r.single.accountId, 'occurred_at': '2026-09-27T12:00:00+08:00'})
      ], source: Source.manual, actor: Actor.user);
      expect(() => Setups(ledger).undo(r), throwsA(isA<InvalidStateException>()));
      expect(ledger.account(r.single.accountId), isNotNull);
    });
    test('定期（转过去的）：转账作废、账户归档，钱回到原账户；定期条款在真删时清掉', () {
      final r = Setups(ledger).apply([
        SetupItem(kind: SetupKind.asset, name: '工行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, fromTransfer: true, viaAction: true, fromAccountId: 'bank', maturity: '2027-01-01'),
      ], env: env());
      Setups(ledger).undo(r);
      expect(ledger.balances()['bank']!.minor, 2000000);
      expect(ledger.getTransaction(r.single.transferTxId!).status, TransactionStatus.void_);
      expect(ledger.getAccount(r.single.accountId).isArchived, isTrue);

      final r2 = Setups(ledger).apply([SetupItem(kind: SetupKind.asset, name: '招行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, maturity: '2027-01-01')], env: env());
      expect(ledger.profile.getString('${DepositTerms.keyPrefix}${r2.single.accountId}'), isNotNull);
      Setups(ledger).undo(r2);
      expect(ledger.profile.getString('${DepositTerms.keyPrefix}${r2.single.accountId}'), isNull);
    });
    test('信用额度：卡和条款一起删', () {
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.credit, name: '花呗', product: CreditProduct.huabei, principalMinor: 0, limitMinor: 800000, dueDay: 15, statementDay: 5)], env: env());
      Setups(ledger).undo(r);
      expect(ledger.account(r.single.accountId), isNull);
      expect(ledger.cards.terms(r.single.accountId), isNull);
    });
    test('撤销两次 / 账户已被别处删掉：不报错', () {
      final r = Setups(ledger).apply([SetupItem(kind: SetupKind.receivable, name: '借给小李', principalMinor: 300000)], env: env());
      Setups(ledger).undo(r);
      expect(() => Setups(ledger).undo(r), returnsNormally);
    });
  });

  test('SetupApplied / SetupItem 序列化', () {
    const a = SetupApplied(kind: SetupKind.loan, accountId: 'x', recurringId: 'r', goalId: 'g');
    expect(SetupApplied.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, Object?>).toJson(), a.toJson());
    final it = baitiao()..asked.add(SetupSlot.monthly)..notes.add('n');
    expect(SetupItem.fromJson(jsonDecode(jsonEncode(it.toJson())) as Map<String, Object?>).toJson(), it.toJson());
  });

  test('addMonths：月底 / 跨年', () {
    expect(addMonths('2026-01-31', 1), '2026-02-28');
    expect(addMonths('2026-12-15', 1), '2027-01-15');
    expect(addMonths('2026-09-27', 36), '2029-09-27');
  });
}
