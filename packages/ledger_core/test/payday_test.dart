import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 0.9.22 发薪日：按真正的今天推、可以几个、看这一期实际到没到。
void main() {
  late LedgerDatabase db;
  late Ledger l;
  var clock = DateTime.utc(2026, 9, 27, 4);

  setUp(() {
    clock = DateTime.utc(2026, 9, 27, 4);
    db = openLedgerDatabaseInMemory();
    l = Ledger(db, clock: () => clock)..seedDefaultCategories();
    l.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
  });
  tearDown(() => db.close());

  void income(String date, int minor, {String cat = 'salary'}) =>
      l.commit(l.propose([DraftInput(payload: {'type': 'income', 'currency': 'CNY', 'amount_minor': minor, 'account_id': 'bank', 'category_id': cat, 'occurred_at': '${date}T09:00:00+08:00'})], source: Source.manual, actor: Actor.user).single.id);
  void spend(String date, int minor) =>
      l.commit(l.propose([DraftInput(payload: {'type': 'expense', 'currency': 'CNY', 'amount_minor': minor, 'account_id': 'bank', 'category_id': 'food', 'occurred_at': '${date}T12:00:00+08:00'})], source: Source.manual, actor: Actor.user).single.id);
  List<String> calendarPaydays(String from, String to, String today) =>
      [for (final d in dueMarks(l, from: from, to: to, today: today)) if (d.kind == DueMarkKind.payday) d.date];

  test('没记工资：按月底估，日历上注明是估的；记了本月工资后，日历不再挂月底，和首页同一个发薪日', () {
    expect(Wealth(l).compute(today: '2026-09-27').paydaySource, 'month_end');
    final marks = dueMarks(l, from: '2026-09-01', to: '2026-09-30', today: '2026-09-27').where((d) => d.kind == DueMarkKind.payday).toList();
    expect(marks.single.date, '2026-09-30');
    expect(marks.single.note, '按月底估的');
    income('2026-09-10', 1500000);
    final m = Wealth(l).compute(today: '2026-09-27');
    expect(m.payday, '2026-10-10');
    expect(calendarPaydays('2026-09-01', '2026-10-31', '2026-09-27'), ['2026-10-10']);
  });

  test('工资提前到（周末提前发）：这一期算发过了，下一次是下个月；不会把整月的钱按 1 天分', () {
    for (final d in ['2026-07-10', '2026-08-10', '2026-09-10']) {
      income(d, 1500000);
    }
    clock = DateTime.utc(2026, 10, 9, 4);
    expect(Wealth(l).compute(today: '2026-10-09').payday, '2026-10-10');
    income('2026-10-09', 1500000);
    final m = Wealth(l).compute(today: '2026-10-09');
    expect(m.payday, '2026-11-10');
    expect(m.daysToPayday, 32);
    expect(calendarPaydays('2026-10-01', '2026-11-30', '2026-10-09'), ['2026-11-10']);
  });

  test('工资晚到：过了日子还没到（上个月这一期有进账）→ 按明天到估、标明晚了；到账后回到下个月；不记工资的人不算晚', () {
    for (final d in ['2026-07-10', '2026-08-10', '2026-09-10']) {
      income(d, 1500000);
    }
    spend('2026-09-20', 1000000);
    clock = DateTime.utc(2026, 10, 11, 4);
    var m = Wealth(l).compute(today: '2026-10-11');
    expect(m.paydayLateSince, '2026-10-10');
    expect(m.payday, '2026-10-12');
    final plan = RepaymentPlanner(l).build(today: '2026-10-11', metrics: m);
    final first = plan.items.firstWhere((i) => i.isIncome);
    expect(first.date, '2026-10-12');
    expect(first.fullMinor, 1500000); // 按这一期近几个月实际到账估
    income('2026-10-11', 1500000);
    m = Wealth(l).compute(today: '2026-10-11');
    expect(m.paydayLateSince, isNull);
    expect(m.payday, '2026-11-10');
    // 晚太久（过了 7 天）就不再等这一期
    final l2 = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 10, 20, 4))..seedDefaultCategories();
    l2.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY');
    l2.profile.payday = 10; // 填了发薪日但从来不记工资
    expect(Wealth(l2).compute(today: '2026-10-11').paydayLateSince, isNull);
    expect(Wealth(l2).compute(today: '2026-10-11').payday, '2026-11-10');
  });

  test('工资、绩效分开发：连续几个月都在另一个日子到的绩效也推成发薪日；各期按各自到账估', () {
    for (final m in ['07', '08', '09']) {
      income('2026-$m-10', 1500000);
      income('2026-$m-25', 300000, cat: 'bonus');
    }
    expect(Paydays(l).infer(today: '2026-09-27'), [10, 25]);
    expect(Paydays(l).schedule(today: '2026-09-27').source, PaydaySource.inferred);
    expect(Wealth(l).compute(today: '2026-09-27').payday, '2026-10-10');
    expect(calendarPaydays('2026-10-01', '2026-10-31', '2026-09-27'), ['2026-10-10', '2026-10-25']);
    expect(Paydays(l).expectedIncome('2026-10-10'), 1500000);
    expect(Paydays(l).expectedIncome('2026-10-25'), 300000);
    // 只来过一次的奖金不算发薪日
    final l2 = Ledger(openLedgerDatabaseInMemory(), clock: () => clock)..seedDefaultCategories();
    l2.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY');
    for (final m in ['07', '08', '09']) {
      l2.commit(l2.propose([DraftInput(payload: {'type': 'income', 'currency': 'CNY', 'amount_minor': 1500000, 'account_id': 'bank', 'category_id': 'salary', 'occurred_at': '2026-$m-10T09:00:00+08:00'})], source: Source.manual, actor: Actor.user).single.id);
    }
    l2.commit(l2.propose([DraftInput(payload: {'type': 'income', 'currency': 'CNY', 'amount_minor': 500000, 'account_id': 'bank', 'category_id': 'bonus', 'occurred_at': '2026-08-20T09:00:00+08:00'})], source: Source.manual, actor: Actor.user).single.id);
    expect(Paydays(l2).infer(today: '2026-09-27'), [10]);
  });

  test('手填几个发薪日：老字段同时写第一个；老版本只改了老字段时以老字段为准', () {
    l.profile.paydays = [25, 10, 10];
    expect(l.profile.paydays, [10, 25]);
    expect(l.profile.payday, 10);
    expect(Paydays(l).schedule(today: '2026-09-27').source, PaydaySource.profile);
    expect(Wealth(l).compute(today: '2026-09-27').payday, '2026-10-10');
    // 老版本把发薪日改成 15 号（只写老字段）
    l.profile.set(ProfileStore.keyPayday, '15');
    expect(l.profile.paydays, [15]);
    l.profile.paydays = const [];
    expect(l.profile.payday, isNull);
    expect(l.profile.paydays, isEmpty);
  });
}
