import 'package:ledger_core/ledger_core.dart';

import 'dsl.dart';

class QueryRow {
  final String key; // 分组键（id / 日期 / 币种）
  final String label; // 展示名
  final String currency;
  final int valueMinor;
  final int count;
  final String? topTransactionId; // max 时是那笔交易

  const QueryRow({
    required this.key,
    required this.label,
    required this.currency,
    required this.valueMinor,
    required this.count,
    this.topTransactionId,
  });

  Map<String, Object?> toJson() => {
        'key': key,
        'label': label,
        'currency': currency,
        'value_minor': valueMinor,
        'value': Money(valueMinor, currency).toDecimalString(),
        'count': count,
        if (topTransactionId != null) 'transaction_id': topTransactionId,
      };
}

/// 查询结果 + 依据：模型据此组织回答，不能凭上下文报数。
class QueryResult {
  final QueryDsl query;
  final List<QueryRow> rows;
  final List<QueryRow>? compareRows;
  final List<String> evidenceTransactionIds;
  final int matchedCount;

  const QueryResult({
    required this.query,
    required this.rows,
    this.compareRows,
    required this.evidenceTransactionIds,
    required this.matchedCount,
  });

  Map<String, Object?> toJson() => {
        'query': query.toJson(),
        'rows': rows.map((r) => r.toJson()).toList(),
        if (compareRows != null) 'compare_rows': compareRows!.map((r) => r.toJson()).toList(),
        'evidence': {'transaction_ids': evidenceTransactionIds, 'matched_count': matchedCount},
      };
}

class QueryEngine {
  final Ledger ledger;
  QueryEngine(this.ledger);

  QueryResult run(QueryDsl q) {
    if (q.metric == Metric.balance) return _balances(q);
    final main = _select(q, q.timeRange);
    final rows = _aggregate(q, main);
    List<QueryRow>? cmp;
    if (q.compareTo != null) cmp = _aggregate(q, _select(q, q.compareTo));
    return QueryResult(
      query: q,
      rows: rows,
      compareRows: cmp,
      evidenceTransactionIds: main.map((e) => e.tx.id).take(200).toList(),
      matchedCount: main.length,
    );
  }

  QueryResult _balances(QueryDsl q) {
    final accounts = ledger.listAccounts();
    final rows = [
      for (final a in accounts)
        if (q.filter.accountIds.isEmpty || q.filter.accountIds.contains(a.id))
          QueryRow(key: a.id, label: a.name, currency: a.currency, valueMinor: ledger.balance(a.id).minor, count: 0),
    ];
    return QueryResult(query: q, rows: rows, evidenceTransactionIds: const [], matchedCount: rows.length);
  }

  /// 命中的交易 + 计入的有符号金额。退款在"支出"口径里记为负数（净支出）。
  List<({Transaction tx, int signed})> _select(QueryDsl q, DateRange? range) {
    DateTime? from;
    DateTime? to;
    if (range != null) {
      // 本地日期转 UTC 粗范围（±1 天）取数，再按交易自身的本地日期精确过滤
      from = DateTime.parse('${range.from}T00:00:00Z').subtract(const Duration(days: 1));
      to = DateTime.parse('${range.to}T00:00:00Z').add(const Duration(days: 2));
    }
    final wantRefundAsNegative = q.types.contains(TransactionType.expense) && !q.types.contains(TransactionType.refund);
    final typeSet = {...q.types, if (wantRefundAsNegative) TransactionType.refund};
    final catSet = _expandCategories(q.filter.categoryIds);
    final out = <({Transaction tx, int signed})>[];
    for (final t in ledger.listTransactions(from: from, to: to, limit: 1 << 30)) {
      if (!typeSet.contains(t.type)) continue;
      if (range != null && !range.contains(t.occurredAt.localDate)) continue;
      if (catSet != null && !catSet.contains(t.categoryId)) continue;
      if (q.filter.accountIds.isNotEmpty && !t.postings.any((p) => q.filter.accountIds.contains(p.accountId))) continue;
      if (q.filter.merchantLike != null) {
        final needle = q.filter.merchantLike!.toLowerCase();
        final hay = '${t.merchant ?? ''} ${t.description ?? ''}'.toLowerCase();
        if (!hay.contains(needle)) continue;
      }
      if (q.filter.tags.isNotEmpty && !q.filter.tags.every(t.tags.contains)) continue;
      final signed = (t.type == TransactionType.refund && wantRefundAsNegative) ? -t.amountMinor : t.amountMinor;
      out.add((tx: t, signed: signed));
    }
    return out;
  }

  Set<String>? _expandCategories(List<String> ids) {
    if (ids.isEmpty) return null;
    final all = ledger.listCategories();
    final children = <String, List<String>>{};
    for (final c in all) {
      if (c.parentId != null) children.putIfAbsent(c.parentId!, () => []).add(c.id);
    }
    final out = <String>{};
    final stack = [...ids];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (out.add(id)) stack.addAll(children[id] ?? const []);
    }
    return out;
  }

  List<QueryRow> _aggregate(QueryDsl q, List<({Transaction tx, int signed})> items) {
    final groups = <String, List<({Transaction tx, int signed})>>{};
    for (final it in items) {
      final key = '${_groupKey(q.groupBy, it.tx)}|${it.tx.currency}';
      groups.putIfAbsent(key, () => []).add(it);
    }
    final rows = <QueryRow>[];
    for (final e in groups.entries) {
      final gk = e.key.substring(0, e.key.lastIndexOf('|'));
      final cur = e.key.substring(e.key.lastIndexOf('|') + 1);
      final list = e.value;
      final sum = list.fold<int>(0, (a, b) => a + b.signed);
      switch (q.metric) {
        case Metric.sum:
          rows.add(QueryRow(key: gk, label: _label(q.groupBy, gk, cur), currency: cur, valueMinor: sum, count: list.length));
        case Metric.count:
          rows.add(QueryRow(key: gk, label: _label(q.groupBy, gk, cur), currency: cur, valueMinor: list.length, count: list.length));
        case Metric.avg:
          rows.add(QueryRow(key: gk, label: _label(q.groupBy, gk, cur), currency: cur, valueMinor: list.isEmpty ? 0 : sum ~/ list.length, count: list.length));
        case Metric.max:
          final top = list.reduce((a, b) => a.signed >= b.signed ? a : b);
          rows.add(QueryRow(key: gk, label: _label(q.groupBy, gk, cur), currency: cur, valueMinor: top.signed, count: list.length, topTransactionId: top.tx.id));
        case Metric.balance:
          break;
      }
    }
    rows.sort((a, b) => q.descending ? b.valueMinor.compareTo(a.valueMinor) : a.valueMinor.compareTo(b.valueMinor));
    return rows.take(q.limit).toList();
  }

  String _groupKey(GroupBy g, Transaction t) => switch (g) {
        GroupBy.none => 'all',
        GroupBy.category => t.categoryId ?? '',
        GroupBy.account => t.accountId,
        GroupBy.merchant => t.merchant ?? t.description ?? '',
        GroupBy.day => t.occurredAt.localDate,
        GroupBy.month => t.occurredAt.localDate.substring(0, 7),
        GroupBy.currency => t.currency,
      };

  String _label(GroupBy g, String key, String currency) => switch (g) {
        GroupBy.none => '合计',
        GroupBy.category => ledger.category(key)?.name ?? (key.isEmpty ? '未分类' : key),
        GroupBy.account => ledger.account(key)?.name ?? key,
        GroupBy.currency => currency,
        _ => key.isEmpty ? '(无)' : key,
      };
}
