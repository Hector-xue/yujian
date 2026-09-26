import 'dart:convert';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 0.9.21：备份带收件箱、账户建立时间跟着走；信用卡只读近几个月明细也和从头算的一样；数据版本号。
void main() {
  Ledger make(DateTime at) => Ledger(openLedgerDatabaseInMemory(), clock: () => at)..seedDefaultCategories();

  Transaction add(Ledger l, Map<String, Object?> p) => l.commit(l.propose([DraftInput(payload: {'currency': 'CNY', ...p})], source: Source.manual, actor: Actor.user).single.id);

  test('JSON 备份带收件箱里待确认的周期账单：恢复后还在、能确认，不会因为 next_due 已经推过去而永远丢掉', () {
    final a = make(DateTime.utc(2026, 9, 26, 4));
    a.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 500000);
    a.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 200000, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-08-10');
    final drafts = a.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480);
    expect(drafts, hasLength(2));
    final json = jsonDecode(exportJsonString(a)) as Map<String, Object?>;
    expect(json['drafts'] as List, hasLength(2));

    final b = make(DateTime.utc(2026, 12, 1, 4)); // 过了两个多月才恢复
    restoreFromJson(b, json);
    final pending = b.listDrafts(status: DraftStatus.pending);
    expect(pending.map((d) => d.id).toSet(), drafts.map((d) => d.id).toSet());
    for (final d in pending) {
      b.commit(d.id);
    }
    expect(b.balance('bank').minor, 500000 - 400000);
    // 再生成不会重复起草已经恢复回来的那两期
    expect(b.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480), isEmpty);
  });

  test('恢复 / 同步后账户的建立时间不变（信用卡判上期逾期要用），老备份没有这一项也照常恢复', () {
    final a = make(DateTime.utc(2026, 7, 1, 4));
    final card = a.cards.add(name: '招行', terms: const CardTerms(limitMinor: 800000, statementDay: 16, dueDay: 6));
    final json = jsonDecode(exportJsonString(a)) as Map<String, Object?>;
    final b = make(DateTime.utc(2026, 12, 1, 4));
    restoreFromJson(b, json);
    expect(b.account(card.id)!.createdAt, a.account(card.id)!.createdAt);
    // 老备份：账户里没有 created_at、也没有 drafts
    final old = {...json, 'drafts': null, 'accounts': [for (final m in (json['accounts'] as List).cast<Map>()) {...m}..remove('created_at')]};
    final c = make(DateTime.utc(2026, 12, 1, 4));
    restoreFromJson(c, old);
    expect(c.account(card.id), isNotNull);
    expect(c.listDrafts(status: DraftStatus.pending), isEmpty);
  });

  test('信用卡只读近几个月明细、更早的合成期初：账单 / 欠款和从头逐笔算的一样', () {
    final l = make(DateTime.utc(2026, 9, 26, 4));
    l.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 50000000);
    final card = l.cards.add(name: '招行', terms: const CardTerms(limitMinor: 3000000, statementDay: 5, dueDay: 25), owedMinor: 12345);
    // 两年流水：每月 3 笔消费、每月 20 号还一部分
    for (var m = 0; m < 24; m++) {
      final base = DateTime.utc(2024, 9 + m, 1);
      for (final d in [3, 11, 27]) {
        final day = DateTime.utc(base.year, base.month, d);
        add(l, {'type': 'expense', 'amount_minor': 10000 + m * 37 + d, 'account_id': card.id, 'category_id': 'shopping', 'occurred_at': '${day.toIso8601String().substring(0, 10)}T12:00:00+08:00'});
      }
      final pay = DateTime.utc(base.year, base.month, 20);
      add(l, {'type': 'transfer', 'amount_minor': 25000, 'account_id': 'bank', 'to_account_id': card.id, 'occurred_at': '${pay.toIso8601String().substring(0, 10)}T20:00:00+08:00'});
    }
    int naiveBalanceAt(String date) {
      var b = card.initialBalanceMinor;
      for (final t in l.listTransactions(accountId: card.id, limit: 1 << 30)) {
        if (t.occurredAt.localDate.compareTo(date) > 0) continue;
        for (final p in t.postings) {
          if (p.accountId == card.id) b += p.amountMinor;
        }
      }
      return b;
    }

    for (final today in ['2026-08-30', '2026-09-04', '2026-09-05', '2026-09-26']) {
      final s = l.cards.status(card.id, today: today)!;
      expect(s.statementMinor, -naiveBalanceAt(s.statementDate) > 0 ? -naiveBalanceAt(s.statementDate) : 0, reason: today);
      expect(s.owedMinor, -l.balance(card.id).minor);
    }
  });

  test('数据版本号：写入后变，只读不变', () {
    final l = make(DateTime.utc(2026, 9, 26, 4));
    l.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 1000);
    final r0 = l.revision;
    l.listTransactions();
    Wealth(l).compute(today: '2026-09-26');
    expect(l.revision, r0);
    add(l, {'type': 'expense', 'amount_minor': 100, 'account_id': 'w', 'category_id': 'food', 'occurred_at': '2026-09-26T09:00:00+08:00'});
    expect(l.revision, greaterThan(r0));
  });
}
