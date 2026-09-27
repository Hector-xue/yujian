import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  test('锚点：组均值落在各组中点分位，中位数正好 50%', () {
    expect(IncomeBenchmark.percentileOf(10150), closeTo(0.10, 1e-9));
    expect(IncomeBenchmark.percentileOf(22702), closeTo(0.30, 1e-9));
    expect(IncomeBenchmark.percentileOf(36231), closeTo(0.50, 1e-9));
    expect(IncomeBenchmark.percentileOf(55586), closeTo(0.70, 1e-9));
    expect(IncomeBenchmark.percentileOf(103778), closeTo(0.90, 1e-9));
  });

  test('尾部与边界：帕累托外推、夹在 1%–99%、单调', () {
    expect(IncomeBenchmark.percentileOf(207556), closeTo(1 - 0.1 * 0.25, 1e-9)); // 两倍高收入组均值
    expect(IncomeBenchmark.percentileOf(0), 0.01);
    expect(IncomeBenchmark.percentileOf(5075), closeTo(0.05, 1e-9));
    expect(IncomeBenchmark.percentileOf(1e9), 0.99);
    var last = 0.0;
    for (var x = 1000.0; x < 2e6; x *= 1.1) {
      final p = IncomeBenchmark.percentileOf(x);
      expect(p, greaterThanOrEqualTo(last));
      last = p;
    }
  });

  test('WealthMetrics.incomeRank：有整月收入按近 3 个整月均值年化，只有近期收入按近 31 天年化，没收入 = null', () {
    final ledger = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 9, 20, 4))..seedDefaultCategories();
    ledger.createAccount(id: 'bank', name: '工资卡', type: AccountType.bank, currency: 'CNY');
    void income(int minor, String date) {
      final d = ledger.propose([DraftInput(payload: {'type': 'income', 'amount_minor': minor, 'currency': 'CNY', 'account_id': 'bank', 'category_id': 'salary', 'occurred_at': '${date}T09:00:00+08:00'})], source: Source.manual, actor: Actor.user).single;
      ledger.commit(d.id);
    }

    expect(Wealth(ledger).compute(today: '2026-09-20').incomeRank, isNull);
    income(300000, '2026-09-10'); // 本月才有：近 31 天 3000 × 12 = 36000
    var r = Wealth(ledger).compute(today: '2026-09-20').incomeRank!;
    expect(r.basis, IncomeRankBasis.recent);
    expect(r.annualMinor, 3600000);
    expect(r.percent, (IncomeBenchmark.percentileOf(36000) * 100).round());
    income(1000000, '2026-08-10');
    income(500000, '2026-07-10'); // 近 3 个整月里两个月有收入：(10000 + 5000) / 2 × 12 = 90000
    r = Wealth(ledger).compute(today: '2026-09-20').incomeRank!;
    expect(r.basis, IncomeRankBasis.history);
    expect(r.annualMinor, 9000000);
    expect(r.percentile, IncomeBenchmark.percentileOf(90000));
  });
}
