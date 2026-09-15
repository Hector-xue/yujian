import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  late Account wechat;

  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 15, 4))..seedDefaultCategories();
    wechat = ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY');
  });
  tearDown(() => db.close());

  Map<String, Object?> rent() => {'type': 'expense', 'amount_minor': 220000, 'currency': 'CNY', 'account_id': wechat.id, 'category_id': 'housing', 'description': '房租'};

  group('advanceDate', () {
    test('month-end alignment and year rollover', () {
      expect(advanceDate('2026-01-31', Frequency.monthly, 1), '2026-02-28');
      expect(advanceDate('2026-12-15', Frequency.monthly, 1), '2027-01-15');
      expect(advanceDate('2026-01-31', Frequency.monthly, 3), '2026-04-30');
      expect(advanceDate('2024-02-29', Frequency.yearly, 1), '2025-02-28');
      expect(advanceDate('2026-09-15', Frequency.weekly, 2), '2026-09-29');
      expect(advanceDate('2026-09-15', Frequency.daily, 1), '2026-09-16');
    });
  });

  group('recurring', () {
    test('generates drafts when due, advances, never double-generates', () {
      final r = ledger.recurring.create(name: '房租', template: rent(), frequency: Frequency.monthly, firstDue: '2026-09-01');
      expect(r.nextDue, '2026-09-01');
      final d1 = ledger.recurring.generateDue(today: '2026-09-15', tzOffsetMinutes: 480);
      expect(d1.length, 1);
      expect(d1.single.source, Source.recurring);
      expect(d1.single.payload['occurred_at'], '2026-09-01T09:00:00+08:00');
      expect(d1.single.payload['amount_minor'], 220000);
      expect(d1.single.missingFields, isEmpty);
      expect(ledger.recurring.get(r.id).nextDue, '2026-10-01');
      expect(ledger.recurring.generateDue(today: '2026-09-15', tzOffsetMinutes: 480), isEmpty);
      // 手动再试同一期：精确指纹丢弃
      expect(ledger.listDrafts(status: DraftStatus.pending).length, 1);
    });

    test('catch-up is capped and then skips to the future', () {
      final r = ledger.recurring.create(name: '会员', template: {...rent(), 'amount_minor': 1500, 'category_id': 'entertainment'}, frequency: Frequency.monthly, firstDue: '2026-01-05');
      final ds = ledger.recurring.generateDue(today: '2026-09-15', tzOffsetMinutes: 480);
      expect(ds.length, 3); // 最多补 3 期
      expect(ledger.recurring.get(r.id).nextDue, '2026-10-05');
    });

    test('inactive and non-auto items are skipped; upcoming lists soon-due', () {
      final a = ledger.recurring.create(name: 'a', template: rent(), frequency: Frequency.monthly, firstDue: '2026-09-10');
      ledger.recurring.setActive(a.id, false);
      ledger.recurring.create(name: 'b', template: rent(), frequency: Frequency.monthly, firstDue: '2026-09-10', autoCreate: false);
      ledger.recurring.create(name: 'c', template: rent(), frequency: Frequency.monthly, firstDue: '2026-09-18');
      expect(ledger.recurring.generateDue(today: '2026-09-15', tzOffsetMinutes: 480), isEmpty);
      expect(ledger.recurring.upcoming(today: '2026-09-15').map((r) => r.name), ['c']);
      expect(ledger.recurring.list().length, 2);
      expect(ledger.recurring.list(activeOnly: false).length, 3);
    });

    test('template validation', () {
      expect(() => ledger.recurring.create(name: 'x', template: {'type': 'expense'}, frequency: Frequency.monthly, firstDue: '2026-09-01'), throwsA(isA<ValidationException>()));
      expect(() => ledger.recurring.create(name: 'x', template: rent(), frequency: Frequency.monthly, firstDue: '9/1'), throwsA(isA<ValidationException>()));
    });
  });

  group('budgets', () {
    String commit(int amt, String cat, String when, {String type = 'expense', String? refundOf}) => ledger
        .commit(ledger.propose([DraftInput(payload: {'type': type, 'amount_minor': amt, 'currency': 'CNY', 'account_id': wechat.id, if (type == 'expense') 'category_id': cat, if (refundOf != null) 'refund_of_id': refundOf, 'occurred_at': '${when}T12:00:00+08:00'})], source: Source.manual).single.id)
        .id;

    test('monthly category budget nets refunds and includes subcategories', () {
      ledger.createCategory(id: 'food.coffee', name: '咖啡', kind: CategoryKind.expense, parentId: 'food');
      final b = ledger.budgets.create(name: '吃饭', categoryId: 'food', amountMinor: 100000, startDate: '2026-09-01');
      commit(30000, 'food', '2026-09-03');
      commit(20000, 'food.coffee', '2026-09-10');
      final big = commit(40000, 'food', '2026-09-12');
      commit(40000, 'food', '2026-09-13', type: 'refund', refundOf: big);
      commit(99900, 'shopping', '2026-09-14');
      commit(50000, 'food', '2026-08-30'); // 上期
      final s = ledger.budgets.status(b.id, today: '2026-09-15');
      expect(s.from, '2026-09-01');
      expect(s.to, '2026-09-30');
      expect(s.spentMinor, 50000);
      expect(s.remainingMinor, 50000);
      expect(s.ratio, 0.5);
      expect(s.overAlert, isFalse);
      ledger.budgets.update(b.id, amountMinor: 55000);
      final s2 = ledger.budgets.status(b.id, today: '2026-09-15');
      expect(s2.overAlert, isTrue);
      expect(s2.exceeded, isFalse);
    });

    test('total budget, weekly period aligned to start, overall statuses', () {
      final b = ledger.budgets.create(name: '每周', amountMinor: 50000, period: BudgetPeriod.weekly, startDate: '2026-09-01');
      commit(30000, 'food', '2026-09-15');
      commit(30000, 'daily', '2026-09-14');
      commit(30000, 'daily', '2026-09-08');
      final s = ledger.budgets.status(b.id, today: '2026-09-15');
      expect(s.from, '2026-09-15');
      expect(s.to, '2026-09-21');
      expect(s.spentMinor, 30000);
      expect(ledger.budgets.statuses(today: '2026-09-15').length, 1);
    });

    test('period range for monthly budget starting mid-month', () {
      final b = ledger.budgets.create(name: 'm', amountMinor: 1, startDate: '2026-01-31');
      expect(BudgetStore.periodRange(b, '2026-03-05'), ('2026-02-28', '2026-03-30'));
      expect(BudgetStore.periodRange(b, '2026-01-31'), ('2026-01-31', '2026-02-27'));
    });

    test('backup carries recurring and budgets', () {
      ledger.recurring.create(name: '房租', template: rent(), frequency: Frequency.monthly, firstDue: '2026-10-01');
      ledger.budgets.create(name: '吃饭', categoryId: 'food', amountMinor: 100000, startDate: '2026-09-01');
      final j = exportJson(ledger);
      final db2 = openLedgerDatabaseInMemory();
      final l2 = Ledger(db2);
      restoreFromJson(l2, j);
      expect(l2.recurring.list().single.name, '房租');
      expect(l2.budgets.list().single.categoryId, 'food');
      db2.close();
    });
  });
}
