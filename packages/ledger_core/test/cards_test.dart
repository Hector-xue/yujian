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
}
