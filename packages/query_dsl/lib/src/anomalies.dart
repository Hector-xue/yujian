import 'package:ledger_core/ledger_core.dart';

/// 异常支出（§19 Phase 2）：与同分类过去 [baselineDays] 天的基线比，超过 max(3×中位数, 均值+2σ) 就算。
/// 同分类样本不够就退到全部支出的基线；基线都不够就不判（宁可漏，不瞎报）。
class Anomaly {
  final Transaction tx;
  final int baselineMedianMinor;
  final double ratio; // 金额 / 中位数
  final String basis; // category | overall
  const Anomaly({required this.tx, required this.baselineMedianMinor, required this.ratio, required this.basis});

  Map<String, Object?> toJson() => {'transaction_id': tx.id, 'amount_minor': tx.amountMinor, 'category_id': tx.categoryId, 'baseline_median_minor': baselineMedianMinor, 'ratio': ratio, 'basis': basis};
}

List<Anomaly> detectAnomalies(Ledger ledger, {required String from, required String to, int baselineDays = 90, int minSamples = 5}) {
  final fromUtc = DateTime.parse('${from}T00:00:00Z').subtract(Duration(days: baselineDays + 1));
  final toUtc = DateTime.parse('${to}T00:00:00Z').add(const Duration(days: 2));
  final all = ledger.listTransactions(from: fromUtc, to: toUtc, type: TransactionType.expense, limit: 1 << 30);
  final out = <Anomaly>[];
  for (final t in all) {
    final d = t.occurredAt.localDate;
    if (d.compareTo(from) < 0 || d.compareTo(to) > 0) continue;
    final windowStart = DateTime.parse('${d}T00:00:00Z').subtract(Duration(days: baselineDays));
    bool inWindow(Transaction x) => x.id != t.id && x.currency == t.currency && x.occurredAt.utc.isAfter(windowStart) && x.occurredAt.localDate.compareTo(d) <= 0;
    var samples = all.where((x) => inWindow(x) && x.categoryId == t.categoryId).map((x) => x.amountMinor).toList();
    var basis = 'category';
    if (samples.length < minSamples) {
      samples = all.where(inWindow).map((x) => x.amountMinor).toList();
      basis = 'overall';
      if (samples.length < minSamples * 2) continue;
    }
    samples.sort();
    final median = samples[samples.length ~/ 2];
    final mean = samples.reduce((a, b) => a + b) / samples.length;
    final variance = samples.fold<double>(0, (acc, v) => acc + (v - mean) * (v - mean)) / samples.length;
    final sigma = variance <= 0 ? 0.0 : _sqrt(variance);
    final threshold = [3.0 * median, mean + 2 * sigma].reduce((a, b) => a > b ? a : b);
    if (t.amountMinor > threshold && median > 0) {
      out.add(Anomaly(tx: t, baselineMedianMinor: median, ratio: t.amountMinor / median, basis: basis));
    }
  }
  out.sort((a, b) => b.ratio.compareTo(a.ratio));
  return out;
}

double _sqrt(double v) {
  // 牛顿法，避免引 dart:math 也行，但这里就用它
  var x = v;
  if (x == 0) return 0;
  for (var i = 0; i < 40; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}
