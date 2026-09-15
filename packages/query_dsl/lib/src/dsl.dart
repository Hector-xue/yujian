import 'package:ledger_core/ledger_core.dart';

enum Metric { sum, count, avg, max, balance }

enum GroupBy { none, category, account, merchant, day, month, currency }

class DateRange {
  /// 本地日期 yyyy-MM-dd，闭区间。
  final String from;
  final String to;
  const DateRange(this.from, this.to);

  static final _re = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  factory DateRange.fromJson(Map<String, Object?> j) {
    final f = j['from'];
    final t = j['to'];
    if (f is! String || t is! String || !_re.hasMatch(f) || !_re.hasMatch(t)) {
      throw const FormatException('time_range.from/to must be yyyy-MM-dd');
    }
    if (f.compareTo(t) > 0) throw const FormatException('time_range.from > to');
    return DateRange(f, t);
  }

  Map<String, Object?> toJson() => {'from': from, 'to': to};
  bool contains(String localDate) => localDate.compareTo(from) >= 0 && localDate.compareTo(to) <= 0;
}

class QueryFilter {
  final List<String> categoryIds;
  final List<String> accountIds;
  final String? merchantLike;
  final List<String> tags;
  const QueryFilter({this.categoryIds = const [], this.accountIds = const [], this.merchantLike, this.tags = const []});

  factory QueryFilter.fromJson(Map<String, Object?> j) => QueryFilter(
        categoryIds: _strList(j['category_ids'], 'filter.category_ids'),
        accountIds: _strList(j['account_ids'], 'filter.account_ids'),
        merchantLike: j['merchant_like'] as String?,
        tags: _strList(j['tags'], 'filter.tags'),
      );

  Map<String, Object?> toJson() => {
        if (categoryIds.isNotEmpty) 'category_ids': categoryIds,
        if (accountIds.isNotEmpty) 'account_ids': accountIds,
        if (merchantLike != null) 'merchant_like': merchantLike,
        if (tags.isNotEmpty) 'tags': tags,
      };
}

/// 一次查询。校验在构造时完成，非法 JSON 直接 FormatException，不会带着歧义去查库。
class QueryDsl {
  final Metric metric;
  final List<TransactionType> types;
  final DateRange? timeRange;
  final GroupBy groupBy;
  final QueryFilter filter;
  final DateRange? compareTo;
  final int limit;
  final bool descending;

  const QueryDsl({
    this.metric = Metric.sum,
    this.types = const [TransactionType.expense],
    this.timeRange,
    this.groupBy = GroupBy.none,
    this.filter = const QueryFilter(),
    this.compareTo,
    this.limit = 20,
    this.descending = true,
  });

  factory QueryDsl.fromJson(Map<String, Object?> j) {
    final metric = _enum(Metric.values, j['metric'], 'metric', Metric.sum);
    final typesRaw = j['type'] ?? j['types'];
    final types = typesRaw == null
        ? const [TransactionType.expense]
        : (typesRaw is String ? [typesRaw] : _strList(typesRaw, 'type'))
            .map((s) => enumFromDb(TransactionType.values, s))
            .toList();
    if (types.isEmpty) throw const FormatException('type must not be empty');
    final order = j['order'];
    return QueryDsl(
      metric: metric,
      types: types,
      timeRange: j['time_range'] == null ? null : DateRange.fromJson((j['time_range'] as Map).cast()),
      groupBy: _enum(GroupBy.values, j['group_by'], 'group_by', GroupBy.none),
      filter: j['filter'] == null ? const QueryFilter() : QueryFilter.fromJson((j['filter'] as Map).cast()),
      compareTo: j['compare_to'] == null ? null : DateRange.fromJson((j['compare_to'] as Map).cast()),
      limit: (j['limit'] as num?)?.toInt().clamp(1, 500) ?? 20,
      descending: order == null || order == 'desc',
    );
  }

  Map<String, Object?> toJson() => {
        'metric': metric.name,
        'type': types.map((t) => t.db).toList(),
        if (timeRange != null) 'time_range': timeRange!.toJson(),
        'group_by': groupBy.name,
        if (filter.toJson().isNotEmpty) 'filter': filter.toJson(),
        if (compareTo != null) 'compare_to': compareTo!.toJson(),
        'limit': limit,
        'order': descending ? 'desc' : 'asc',
      };
}

T _enum<T extends Enum>(List<T> values, Object? raw, String field, T dflt) {
  if (raw == null) return dflt;
  if (raw is! String) throw FormatException('$field must be a string');
  return values.firstWhere((v) => v.name == raw, orElse: () => throw FormatException('$field: unknown value $raw'));
}

List<String> _strList(Object? raw, String field) {
  if (raw == null) return const [];
  if (raw is! List || !raw.every((e) => e is String)) throw FormatException('$field must be a list of strings');
  return raw.cast<String>();
}
