import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  late Account card;

  const terms = CardTerms(limitMinor: 1000000, statementDay: 5, dueDay: 25); // 额度 1 万，5 号出账，25 号还

  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 30, 4))..seedDefaultCategories();
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 5000000);
    card = ledger.cards.add(name: '招行信用卡', terms: terms);
  });
  tearDown(() => db.close());

  Transaction add(Map<String, Object?> payload) {
    final d = ledger.propose([DraftInput(payload: payload)], source: Source.manual, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  void spend(int minor, String date) =>
      add({'type': 'expense', 'amount_minor': minor, 'currency': 'CNY', 'account_id': card.id, 'category_id': 'shopping', 'occurred_at': '${date}T12:00:00+08:00'});
  void repay(int minor, String date, {String? to}) =>
      add({'type': 'transfer', 'amount_minor': minor, 'currency': 'CNY', 'account_id': 'bank', 'to_account_id': to ?? card.id, 'occurred_at': '${date}T20:00:00+08:00'});

  group('dates', () {
    test('statement / due / month arithmetic', () {
      expect(CreditCards.lastStatementDate('2026-09-10', 5), '2026-09-05');
      expect(CreditCards.lastStatementDate('2026-09-05', 5), '2026-09-05'); // 账单日当天算本期出账
      expect(CreditCards.lastStatementDate('2026-09-03', 5), '2026-08-05');
      expect(CreditCards.lastStatementDate('2026-01-03', 5), '2025-12-05');
      expect(CreditCards.dueDateFor('2026-09-05', 25), '2026-09-25'); // 还款日在账单日之后：当月
      expect(CreditCards.dueDateFor('2026-08-20', 8), '2026-09-08'); // 还款日数字更小：次月
      expect(CreditCards.dueDateFor('2026-12-20', 20), '2027-01-20'); // 同一天：次月
      expect(CreditCards.addMonths('2026-12-05', 1), '2027-01-05');
      expect(CreditCards.addMonths('2026-01-05', -1), '2025-12-05');
      expect(CreditCards.daysBetween('2026-09-10', '2026-09-25'), 15);
    });
  });

  group('status', () {
    test('没设条款的信用卡不出状态；坏 JSON 当没设', () {
      final bare = ledger.createAccount(name: '旧卡', type: AccountType.creditCard, currency: 'CNY');
      expect(ledger.cards.status(bare.id, today: '2026-09-10'), isNull);
      ledger.profile.set('card:${bare.id}', '{not json');
      expect(ledger.cards.terms(bare.id), isNull);
      expect(ledger.cards.list(today: '2026-09-10').map((s) => s.account.id), [card.id]);
    });

    test('还进去再花出来：额度按此刻欠款，账单按账单日欠款；账单日后还的算还本期、后刷的进下期', () {
      spend(300000, '2026-08-10');
      spend(200000, '2026-08-20');
      repay(200000, '2026-09-08');
      spend(100000, '2026-09-09');
      final s = ledger.cards.status(card.id, today: '2026-09-10')!;
      expect(s.statementDate, '2026-09-05');
      expect(s.dueDate, '2026-09-25');
      expect(s.nextStatementDate, '2026-10-05');
      expect(s.statementMinor, 500000);
      expect(s.repaidMinor, 200000);
      expect(s.remainingMinor, 300000);
      expect(s.newChargesMinor, 100000);
      expect(s.owedMinor, 400000);
      expect(s.availableMinor, 600000); // 还了 2000 额度回来，又刷 1000 占掉
      expect(s.usedRatio, closeTo(0.4, 1e-9));
      expect(s.minPaymentMinor, 50000);
      expect(s.minRemainingMinor, 0);
      expect(s.state, CardBillState.due);
      expect(s.daysToDue, 15);
      expect(s.lateFeeMinor, 0);
      expect(s.interestMinor, 0); // 还没到期：不算利息

      // 试算：到期不再还（一共还 2000 ≥ 最低 500）——全额计息，按日万分之五算到下个账单日 10/5
      // 3000 × 10 天(8/10–8/19) + 5000 × 19 天(8/20–9/7) + 3000 × 27 天(9/8–10/4) = 2060 万分·天 × 0.0005 = 103.00
      final p = ledger.cards.project(s, totalPayMinor: 200000);
      expect(p.lateFeeMinor, 0);
      expect(p.interestMinor, 10300);
      // 还清：免息
      expect(ledger.cards.project(s, totalPayMinor: 500000).costMinor, 0);

      // 未还部分计息：到期前按没还的 60% 计、到期后按实际没还的计
      // (3000×10 + 5000×19 + 3000×18) × 0.6 + 3000 × 9 天(9/26–10/4) = 1344 万 × 0.0005 = 67.20
      ledger.cards.setTerms(card.id, terms.copyWith(mode: CardInterestMode.unpaid));
      final su = ledger.cards.status(card.id, today: '2026-09-10')!;
      expect(ledger.cards.project(su, totalPayMinor: 200000).interestMinor, 6720);
    });

    test('逾期：还够最低只有利息；没还够最低还有违约金（差额 × 5%）', () {
      spend(300000, '2026-08-10');
      spend(200000, '2026-08-20');
      // 一分没还，9/28 已过还款日
      var s = ledger.cards.status(card.id, today: '2026-09-28')!;
      expect(s.state, CardBillState.overdue);
      expect(s.daysToDue, -3);
      expect(s.lateFeeMinor, 2500); // (500 − 0) × 5%
      // 3000 × 10 + 5000 × 46 天(8/20–10/4) = 2600 万 × 0.0005 = 130.00
      expect(s.interestMinor, 13000);
      expect(s.overdueTotalMinor, 500000 + 2500 + 13000);

      // 到期前还了 300（不够最低 500）：违约金按差额 200 × 5% = 10
      repay(30000, '2026-09-20');
      s = ledger.cards.status(card.id, today: '2026-09-28')!;
      expect(s.lateFeeMinor, 1000);
      // 有最低收费的行按最低
      ledger.cards.setTerms(card.id, terms.copyWith(lateFeeMinMinor: 2000));
      expect(ledger.cards.status(card.id, today: '2026-09-28')!.lateFeeMinor, 2000);
      ledger.cards.setTerms(card.id, terms);

      // 逾期后补还清：状态变已还（银行会在下期账单收这段利息，这里不再显示逾期）
      repay(470000, '2026-09-28');
      s = ledger.cards.status(card.id, today: '2026-09-28')!;
      expect(s.state, CardBillState.paid);
      expect(s.remainingMinor, 0);
    });

    test('最低还款：超额度的部分全额进最低还款；账单小于比例算出来的数时不超过账单', () {
      expect(CreditCards.minPayment(500000, terms.copyWith(limitMinor: 400000)), 50000 + 100000);
      expect(CreditCards.minPayment(123, terms), 13); // 12.3 分向上取整
      expect(CreditCards.minPayment(0, terms), 0);
      expect(CreditCards.minPayment(100, terms.copyWith(minPayRatio: 1)), 100);
    });

    test('期初欠款算进账单（建卡时填的「现在欠多少」按已出账处理），溢缴款抬高可用额度', () {
      final c2 = ledger.cards.add(name: '中行', terms: terms, owedMinor: 80000);
      var s = ledger.cards.status(c2.id, today: '2026-09-10')!;
      expect(s.statementMinor, 80000);
      expect(s.state, CardBillState.due);
      repay(100000, '2026-09-10', to: c2.id); // 多还 200
      s = ledger.cards.status(c2.id, today: '2026-09-10')!;
      expect(s.state, CardBillState.paid);
      expect(s.owedMinor, 0);
      expect(s.overpaidMinor, 20000);
      expect(s.availableMinor, 1020000);
    });

    test('花呗 / 月付：按时还清免息，逾期后只对没还的部分按日计息', () {
      ledger.cards.setTerms(card.id, CreditProduct.huabei.defaults(limitMinor: 1000000).copyWith(statementDay: 5, dueDay: 25));
      spend(300000, '2026-08-10');
      spend(200000, '2026-08-20');
      repay(200000, '2026-09-08');
      final s = ledger.cards.status(card.id, today: '2026-09-10')!;
      // 还清：0；只还了 2000 就不管：3000 × 9 天(9/26–10/4) × 0.0005 = 13.50
      expect(ledger.cards.project(s, totalPayMinor: 500000).costMinor, 0);
      final p = ledger.cards.project(s, totalPayMinor: 200000);
      expect(p.interestMinor, 1350);
      expect(p.lateFeeMinor, 0); // 花呗没有银行那种 5% 违约金
      expect(ledger.cards.status(card.id, today: '2026-09-28')!.interestMinor, 1350);
    });

    test('白条：不计利息，逾期按未还金额每天 0.07% 收违约金', () {
      ledger.cards.setTerms(card.id, CreditProduct.baitiao.defaults(limitMinor: 1000000).copyWith(statementDay: 5, dueDay: 25));
      spend(300000, '2026-08-10');
      spend(200000, '2026-08-20');
      repay(200000, '2026-09-08');
      final s = ledger.cards.status(card.id, today: '2026-09-28')!;
      expect(s.state, CardBillState.overdue);
      expect(s.interestMinor, 0);
      expect(s.lateFeeMinor, 1890); // 3000 × 0.0007 × 9 天 = 18.90
    });

    test('分付：按天计息，按时还清也有利息；逾期日利率 × 1.5；不到 100 元要全还', () {
      ledger.cards.setTerms(card.id, CreditProduct.fenfu.defaults(limitMinor: 1000000).copyWith(statementDay: 5, dueDay: 25));
      spend(300000, '2026-08-10');
      spend(200000, '2026-08-20');
      repay(200000, '2026-09-08');
      var s = ledger.cards.status(card.id, today: '2026-09-10')!;
      // 9/25 当天还清剩下的 3000：(3000×10 + 5000×19 + 3000×17 天) × 0.0004 = 70.40
      expect(s.interestMinor, 7040);
      expect(ledger.cards.project(s, totalPayMinor: 500000).interestMinor, 7040);
      // 不再还：到期前 (3000×10 + 5000×19 + 3000×18) × 0.0004 = 71.60，逾期 9 天 3000 × 0.0006 = 16.20 → 87.80
      s = ledger.cards.status(card.id, today: '2026-09-28')!;
      expect(s.interestMinor, 8780);
      expect(s.lateFeeMinor, 0);
      final t = ledger.cards.terms(card.id)!;
      expect(CreditCards.minPayment(9000, t), 9000);
      expect(CreditCards.minPayment(20000, t), 2000);
    });

    test('按产品建：图标和默认条款跟产品走；建好能改名；旧版存的条款（没有新字段）照常读', () {
      final hb = ledger.cards.add(name: '花呗', terms: CreditProduct.huabei.defaults(limitMinor: 500000));
      expect(hb.icon, '🌸');
      final t = ledger.cards.terms(hb.id)!;
      expect(t.product, CreditProduct.huabei);
      expect((t.statementDay, t.dueDay), (1, 9));
      expect(t.mode, CardInterestMode.afterDue);
      expect(ledger.cards.rename(hb.id, ' 我的花呗 ').name, '我的花呗');
      expect(() => ledger.cards.rename(hb.id, '  '), throwsArgumentError);
      final old = CardTerms.fromJson({'limit': 100, 'statement_day': 5, 'due_day': 25, 'daily_rate': 0.0005, 'min_ratio': 0.1, 'late_fee_rate': 0.05, 'late_fee_min': 0, 'mode': 'unpaid'})!;
      expect(old.mode, CardInterestMode.unpaid);
      expect(old.product, CreditProduct.bank);
      expect(old.overdueMultiplier, 1);
      expect(old.lateFeeDailyRate, 0);
      final round = CardTerms.fromJson(CreditProduct.fenfu.defaults(limitMinor: 1).toJson())!;
      expect(round.mode, CardInterestMode.daily);
      expect(round.overdueMultiplier, 1.5);
      expect(round.minFullBelowMinor, 10000);
      for (final p in CreditProduct.values) {
        for (final (sd, dd) in p.dayOptions) {
          expect(sd, inInclusiveRange(1, 28));
          expect(dd, inInclusiveRange(1, 28));
        }
      }
    });

    test('条款随画像同步；删卡连条款一起删；非信用卡不能设条款', () {
      expect(ledger.changes.pending().any((c) => c.entity == 'profile' && c.entityId == 'card:${card.id}'), isTrue);
      final fresh = ledger.cards.add(name: '没刷过', terms: terms);
      ledger.deleteAccount(fresh.id);
      expect(ledger.profile.getString('card:${fresh.id}'), isNull);
      expect(() => ledger.cards.setTerms('bank', terms), throwsArgumentError);
      // 往返
      final back = CardTerms.fromJson(terms.copyWith(mode: CardInterestMode.unpaid, lateFeeMinMinor: 1000).toJson())!;
      expect(back.mode, CardInterestMode.unpaid);
      expect(back.lateFeeMinMinor, 1000);
      expect(back.statementDay, 5);
      expect(CardTerms.fromJson({'limit': 1, 'statement_day': 40, 'due_day': 0})!.statementDay, 28);
    });
  });

  group('负债合计里的信用卡', () {
    test('每月还款 = 贷款月供 + 每张卡最近一期要还的；贷款还清取最晚那笔，不拿总余额 ÷ 总月供', () {
      // 招行：8/10 刷 3000 → 9/5 出账 3000，9/25 到期；9/8 又刷 500（进下期，不算这期）
      spend(300000, '2026-08-10');
      spend(50000, '2026-09-08');
      // 没设账单日的卡：算不出账单，按全部欠款算
      ledger.createAccount(id: 'bare', name: '旧卡', type: AccountType.creditCard, currency: 'CNY', initialBalanceMinor: -80000);
      // 本期已还清的卡：最近一期 = 出账后新刷的
      final paid = ledger.cards.add(name: '中行', terms: terms);
      add({'type': 'expense', 'amount_minor': 100000, 'currency': 'CNY', 'account_id': paid.id, 'category_id': 'shopping', 'occurred_at': '2026-08-11T12:00:00+08:00'});
      repay(100000, '2026-09-06', to: paid.id);
      add({'type': 'expense', 'amount_minor': 20000, 'currency': 'CNY', 'account_id': paid.id, 'category_id': 'shopping', 'occurred_at': '2026-09-07T12:00:00+08:00'});
      // 两笔安逸花（截图里的数）：1701.99 每月 189.11（9 个月），999.72 每月 499.86（2 个月）
      ledger.debts.add(name: '安逸花', kind: DebtKind.online, owedMinor: 170199, monthlyMinor: 18911, day: 26, fromAccountId: 'bank', today: '2026-09-10');
      ledger.debts.add(name: '安逸花', kind: DebtKind.online, owedMinor: 99972, monthlyMinor: 49986, day: 26, fromAccountId: 'bank', today: '2026-09-10');

      expect(ledger.cards.status(paid.id, today: '2026-09-10')!.state, CardBillState.paid);
      var t = ledger.debts.totals(today: '2026-09-10');
      expect(t.loanMinor, 270171);
      expect(t.loanMonthlyMinor, 68897);
      // 招行本期还剩 3000（9/8 刷的 500 进下期）；旧卡按全部欠款 800；中行本期还清、下期已刷 200
      expect(ledger.cards.status(card.id, today: '2026-09-10')!.remainingMinor, 300000);
      expect(t.cardDueMinor, 300000 + 80000 + 20000);
      expect(t.cardsWithoutTerms, 1);
      expect(t.monthlyMinor, 68897 + 400000);
      expect(t.cardMinor, 350000 + 80000 + 20000);
      expect(t.monthsLeft, 9); // 旧算法 270171 ÷ 68897 = 4 个月，错
      // 等级 / 可花的只扣贷款月供：信用卡刷的时候已经记成支出了
      expect(Wealth(ledger).compute(today: '2026-09-10').repaymentMonthlyMinor, 68897);

      // 过了还款日没还：连违约金和利息
      final over = ledger.cards.status(card.id, today: '2026-09-28')!;
      expect(over.state, CardBillState.overdue);
      t = ledger.debts.totals(today: '2026-09-28');
      expect(t.cardDueMinor, over.overdueTotalMinor + 80000 + 20000);
      expect(over.overdueTotalMinor, greaterThan(300000));

      // 有一笔欠着却没设每月还款：永远还不清，说不出月数
      ledger.debts.add(name: '借朋友', kind: DebtKind.loan, owedMinor: 100000, fromAccountId: 'bank', today: '2026-09-10');
      t = ledger.debts.totals(today: '2026-09-10');
      expect(t.loansWithoutRepayment, 1);
      expect(t.monthsLeft, isNull);
      expect(t.loanMonthlyMinor, 68897);
    });

    test('只有信用卡：没有贷款时还清月数是 0，每月还款只含卡账单', () {
      spend(300000, '2026-08-10');
      final t = ledger.debts.totals(today: '2026-09-10');
      expect(t.loanMinor, 0);
      expect(t.monthsLeft, 0);
      expect(t.loanMonthlyMinor, 0);
      expect(t.monthlyMinor, 300000);
    });
  });
}
