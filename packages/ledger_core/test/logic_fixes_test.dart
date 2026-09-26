import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 0.9.19 全面逻辑审查修的问题：每条一个回归。
void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  var clock = DateTime.utc(2026, 9, 26, 4);

  setUp(() {
    clock = DateTime.utc(2026, 9, 26, 4);
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => clock)..seedDefaultCategories();
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 5000000);
    ledger.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 100000);
  });
  tearDown(() => db.close());

  Transaction add(Map<String, Object?> p, {Source source = Source.manual}) {
    final d = ledger.propose([DraftInput(payload: {'currency': 'CNY', ...p})], source: source, actor: Actor.user).single;
    return ledger.commit(d.id);
  }

  List<String> dates(List<Draft> ds) => [for (final d in ds) (d.payload['occurred_at'] as String).substring(0, 10)];

  group('周期账单', () {
    test('每月 31 号的账单过了 2 月回到 31 号，不会永远停在 28 号；每年 2/29 的闰年回到 29', () {
      var d = '2026-01-31';
      final seq = <String>[];
      for (var i = 0; i < 4; i++) {
        d = advanceDate(d, Frequency.monthly, 1, anchorDay: 31);
        seq.add(d);
      }
      expect(seq, ['2026-02-28', '2026-03-31', '2026-04-30', '2026-05-31']);
      expect(advanceDate('2031-02-28', Frequency.yearly, 1, anchorDay: 29), '2032-02-29');
      // 建的时候记下原本是几号，起草时一路对齐
      final r = ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-01-31');
      expect(r.anchorDay, 31);
      clock = DateTime.utc(2026, 4, 1, 4);
      final ds = ledger.recurring.generateDue(today: '2026-03-31', tzOffsetMinutes: 480);
      expect(dates(ds), ['2026-01-31', '2026-02-28', '2026-03-31']);
      expect(ledger.recurring.get(r.id).nextDue, '2026-04-30');
      // 锚定日不进交易的 metadata
      expect((ds.first.payload['metadata'] as Map).containsKey('anchor_day'), isFalse);
    });

    test('老数据补锚定日：从落过账的交易里认出原本是 31 号，next_due 挪回去', () {
      final r = ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-01-31');
      // 模拟老版本：模板里没有 anchor_day，next_due 已经漂成 28 号，历史里有一笔 1/31 的
      db.execute('UPDATE recurring SET template = ?, next_due = ? WHERE id = ?', ['{"type":"expense","amount_minor":100,"currency":"CNY","account_id":"bank","category_id":"housing"}', '2026-10-28', r.id]);
      add({'type': 'expense', 'amount_minor': 100, 'account_id': 'bank', 'category_id': 'housing', 'occurred_at': '2026-01-31T09:00:00+08:00'});
      db.execute('UPDATE transactions SET recurring_id = ?', [r.id]);
      ledger.recurring.backfillAnchors();
      final after = ledger.recurring.get(r.id);
      expect(after.anchorDay, 31);
      expect(after.nextDue, '2026-10-31');
    });

    test('太久没打开：普通账单补最近 3 期（不是最早 3 期），跳过的记下来', () {
      final r = ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 200000, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-03-10');
      final ds = ledger.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480);
      expect(dates(ds), ['2026-07-10', '2026-08-10', '2026-09-10']);
      expect(ledger.recurring.lastSkipped.single.recurring.id, r.id);
      expect(ledger.recurring.lastSkipped.single.dates, ['2026-03-10', '2026-04-10', '2026-05-10', '2026-06-10']);
      expect(ledger.recurring.get(r.id).nextDue, '2026-10-10');
    });

    test('还贷每期都补上（真金白银），最后一期只还零头，还清了自动停，不多还、不再扣可花的', () {
      final s = ledger.debts.add(name: '安逸花', kind: DebtKind.online, owedMinor: 40000, monthlyMinor: 18911, day: 26, fromAccountId: 'bank', today: '2026-06-01');
      final ds = ledger.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480);
      expect(ds.map((d) => d.payload['amount_minor']), [18911, 18911, 2178]); // 6/26、7/26、8/26（最后一期是零头），9/26 已经没得还
      expect(ledger.recurring.lastSkipped, isEmpty);
      expect(ledger.recurring.list(activeOnly: false).single.isActive, isFalse);
      // 还没确认前：可花的已经把这三笔算上了，但不会再多扣以后的期
      final m = Wealth(ledger).compute(today: '2026-09-26');
      expect(m.fixedDueMinor, 40000);
      for (final d in ds) {
        ledger.commit(d.id);
      }
      expect(ledger.debts.list().single.owedMinor, 0);
      expect(ledger.balance(s.account.id).minor, 0);
      expect(Wealth(ledger).compute(today: '2026-09-26').fixedDueMinor, 0);
      expect(RepaymentPlanner(ledger).build(today: '2026-09-26').items.where((i) => i.kind == PlanItemKind.loan), isEmpty);
      expect(ledger.recurring.generateDue(today: '2026-10-27', tzOffsetMinutes: 480), isEmpty);
    });

    test('还款计划 / 可花的：分期剩下的不够一期时只算零头', () {
      ledger.profile.payday = 30;
      ledger.debts.add(name: '网贷', kind: DebtKind.online, owedMinor: 5000, monthlyMinor: 18911, day: 28, fromAccountId: 'bank', today: '2026-09-26');
      final m = Wealth(ledger).compute(today: '2026-09-26');
      expect(m.fixedDueMinor, 5000);
      final plan = RepaymentPlanner(ledger).build(today: '2026-09-26', metrics: m);
      expect(plan.items.where((i) => i.kind == PlanItemKind.loan).map((i) => i.fullMinor), [5000]);
    });

    test('扣款账户归档：用它的周期账单一起停掉，不再起草确认不了的草稿', () {
      ledger.createAccount(id: 'old', name: '旧卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 80000);
      final r = ledger.recurring.create(name: '话费', template: {'type': 'expense', 'amount_minor': 5000, 'currency': 'CNY', 'account_id': 'old', 'category_id': 'shopping'}, frequency: Frequency.monthly, firstDue: '2026-09-20');
      expect(ledger.recurringUsing('old').map((x) => x.id), [r.id]);
      expect(ledger.archiveAccount('old'), 1);
      expect(ledger.recurring.get(r.id).isActive, isFalse);
      expect(ledger.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480), isEmpty);
    });
  });

  group('信用卡', () {
    test('上期没还、出了新账单还是逾期（违约金 / 利息 / 逾期天数按上期算）；出账后还够了上期就不再逾期', () {
      final c = ledger.cards.add(name: '招行', terms: const CardTerms(limitMinor: 1000000, statementDay: 16, dueDay: 6));
      add({'type': 'expense', 'amount_minor': 300000, 'account_id': c.id, 'category_id': 'shopping', 'occurred_at': '2026-08-10T12:00:00+08:00'});
      final before = ledger.cards.status(c.id, today: '2026-09-10')!;
      expect(before.state, CardBillState.overdue);
      var s = ledger.cards.status(c.id, today: '2026-09-20')!;
      expect(s.statementDate, '2026-09-16');
      expect(s.state, CardBillState.overdue);
      expect(s.overdueSince, '2026-09-06');
      expect(s.overdueDays, 14);
      expect(s.lateFeeMinor, before.lateFeeMinor);
      expect(s.lateFeeMinor, greaterThan(0));
      expect(s.overdueTotalMinor, greaterThan(300000));
      add({'type': 'transfer', 'amount_minor': 300000, 'account_id': 'bank', 'to_account_id': c.id, 'occurred_at': '2026-09-18T12:00:00+08:00'});
      s = ledger.cards.status(c.id, today: '2026-09-20')!;
      expect(s.state, isNot(CardBillState.overdue));
    });

    test('建卡时填的「现在欠多少」不算上一期的：新建的卡不会一建就「上期逾期」', () {
      final c = ledger.cards.add(name: '中行', terms: const CardTerms(limitMinor: 800000, statementDay: 16, dueDay: 6), owedMinor: 811828);
      final s = ledger.cards.status(c.id, today: '2026-09-26')!;
      expect(s.state, CardBillState.due);
      expect(s.remainingMinor, 811828);
    });
  });

  group('交易', () {
    test('退过款的原单：金额不能改得比已退的少，也不能换币种；改大照常', () {
      final shoe = add({'type': 'expense', 'amount_minor': 30000, 'account_id': 'w', 'category_id': 'shopping', 'occurred_at': '2026-09-12T12:00:00+08:00'});
      add({'type': 'refund', 'amount_minor': 20000, 'account_id': 'w', 'refund_of_id': shoe.id, 'occurred_at': '2026-09-14T12:00:00+08:00'});
      Transaction update(Map<String, Object?> patch) => ledger.commit(ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: shoe.id, payload: patch)], source: Source.manual, actor: Actor.user).single.id);
      expect(() => update({'amount_minor': 5000}), throwsA(isA<InvalidStateException>()));
      expect(ledger.getTransaction(shoe.id).amountMinor, 30000);
      expect(update({'amount_minor': 20000}).amountMinor, 20000); // 等于已退的可以
      expect(update({'amount_minor': 35000}).amountMinor, 35000);
    });
  });

  group('账单导入', () {
    const header = '交易时间,交易类型,交易对方,商品,收/支,金额(元),当前状态\n';

    test('全额退款：原单「已全额退款」没导，退款在账本里也找不到原单 → 不记（不再留一笔确认不了的退款）', () {
      final rows = parseBillCsv('$header'
          '2026-09-13 09:00:00,商户消费,美团,外卖,支出,¥32.50,已全额退款\n'
          '2026-09-14 12:31:05,美团-退款,美团,外卖,收入,¥32.50,已退款\n');
      final net = netImportedRefunds(rows, linked: (_) => false);
      expect(net.rows, isEmpty);
      expect(net.orphans.single.amountMinor, 3250);
    });

    test('部分退款：同一个文件里的退款冲减到原单上，退款行不单独进来', () {
      final rows = parseBillCsv('$header'
          '2026-09-13 09:00:00,商户消费,美团,外卖,支出,¥32.50,已退款(￥10.00)\n'
          '2026-09-14 12:31:05,美团-退款,美团,外卖,收入,¥10.00,已退款\n');
      final net = netImportedRefunds(rows, linked: (_) => false);
      expect(net.rows.single.type, 'expense');
      expect(net.rows.single.amountMinor, 2250);
      expect(net.rows.single.refundedMinor, 1000);
      expect(importedRowToDraft(net.rows.single).payload['metadata'], containsPair('refunded_in_bill', 1000));
      expect(net.orphans, isEmpty);
    });

    test('账本里已经有原单（通知记过的）：退款照常挂上去，不在文件里冲减', () {
      final rows = parseBillCsv('${header}2026-09-14 12:31:05,美团-退款,美团,外卖,收入,¥32.50,已退款\n');
      final net = netImportedRefunds(rows, linked: (_) => true);
      expect(net.rows.single.type, 'refund');
      expect(net.orphans, isEmpty);
    });
  });

  group('目标', () {
    test('没设锁仓的应急金只算没锁进别的目标的钱：心愿里攒的不能再算一遍', () {
      final wish = ledger.goals.create(kind: GoalKind.wish, name: '旅行', targetMinor: 1000000);
      add(ledger.goals.depositPayload(wish, 300000, fromAccountId: 'bank'));
      final emergency = ledger.goals.create(kind: GoalKind.emergency, name: '应急金', targetMinor: 10000000, withVault: false);
      final m = Wealth(ledger).compute(today: '2026-09-26');
      expect(m.freeLiquidMinor, m.cashMinor - 300000);
      expect(ledger.goals.progress(emergency, today: '2026-09-26', liquidMinor: m.freeLiquidMinor).savedMinor, 5100000 - 300000);
    });

    test('同一个目标的几条发薪日规则共用还差的额度，加起来不超过目标', () {
      ledger.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 100000, rules: const [
        GoalRule(kind: GoalRuleKind.salaryPct, pct: 50),
        GoalRule(kind: GoalRuleKind.fixed, every: 'monthly', day: 10, amountMinor: 80000),
      ]);
      final plan = ledger.goals.paydayPlan(1000000);
      expect(plan.fold(0, (a, b) => a + b.amountMinor), 100000);
    });
  });

  group('记录与任务', () {
    test('连续记录只认用户自己记的：周期账单 / 自动定存不算', () {
      add({'type': 'expense', 'amount_minor': 100, 'account_id': 'bank', 'category_id': 'shopping', 'occurred_at': '2026-09-25T09:00:00+08:00'}, source: Source.recurring);
      add({'type': 'expense', 'amount_minor': 100, 'account_id': 'bank', 'category_id': 'shopping', 'occurred_at': '2026-09-26T09:00:00+08:00'});
      final days = ledger.recordedDates(from: DateTime.utc(2026, 9, 20));
      expect(days, {'2026-09-26'});
    });
  });
}
