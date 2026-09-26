import 'package:ledger_core/ledger_core.dart';

import 'widgets/fmt.dart';

/// 记录页一页取多少笔。
const recordPageSize = 500;

/// 记录页的一页：最近 [limit] 笔，另外把被截在中间的最早那天补全——
/// 否则那天的小计只算了一半，和日历上同一天的数对不上。[hasMore] = 更早还有记录（页面显示「加载更多」）。
({List<Transaction> txs, bool hasMore}) loadRecordPage(Ledger ledger, {required int limit}) {
  final base = ledger.listTransactions(limit: limit);
  if (base.length < limit) return (txs: base, hasMore: false);
  final oldest = base.last.occurredAt.localDate;
  final day = DateTime.parse('${oldest}T00:00:00Z');
  final seen = {for (final t in base) t.id};
  // 按 occurred_at 倒序取的前 N 笔：同一天没取到的都比 base.last 更早，按原顺序接在后面即可
  final rest = [
    for (final t in ledger.listTransactions(from: day.subtract(const Duration(days: 1)), to: day.add(const Duration(days: 2)), limit: 1 << 30))
      if (t.occurredAt.localDate == oldest && !seen.contains(t.id)) t,
  ];
  final txs = [...base, ...rest];
  return (txs: txs, hasMore: ledger.countTransactions() > txs.length);
}

/// 一天的小计：按币种分开（人民币和美元不能加在一起），支出扣掉退款；只有退款的币种写「退回」。人民币排前面。全是 0 = 空串。
String recordDaySummary(List<Transaction> ts) {
  final net = <String, int>{};
  for (final t in ts) {
    if (t.type == TransactionType.expense) net[t.currency] = (net[t.currency] ?? 0) + t.amountMinor;
    if (t.type == TransactionType.refund) net[t.currency] = (net[t.currency] ?? 0) - t.amountMinor;
  }
  final order = net.keys.toList()..sort((a, b) => a == 'CNY' ? -1 : (b == 'CNY' ? 1 : a.compareTo(b)));
  final out = [for (final c in order) if (net[c]! > 0) fmtMoney(net[c]!, c)];
  final back = [for (final c in order) if (net[c]! < 0) fmtMoney(-net[c]!, c)];
  return [if (out.isNotEmpty) '支出 ${out.join(' + ')}', if (back.isNotEmpty) '退回 ${back.join(' + ')}'].join(' · ');
}
