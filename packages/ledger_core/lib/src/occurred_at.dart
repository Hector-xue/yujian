/// 交易发生时间：UTC 瞬间 + 记录时的本地偏移。
/// Dart 原生 DateTime 只有 UTC/本机本地两种时区，不能承载任意偏移，所以单独建值类型。
/// 存储：UTC 毫秒 + 偏移分钟；范围查询按毫秒；展示与 ISO 输出按偏移还原墙上时间。
class OccurredAt implements Comparable<OccurredAt> {
  final DateTime utc;
  final int offsetMinutes;

  OccurredAt(DateTime instant, this.offsetMinutes) : utc = instant.toUtc();

  factory OccurredAt.fromLocal(DateTime local) =>
      OccurredAt(local, local.timeZoneOffset.inMinutes);

  factory OccurredAt.fromMillis(int ms, int offsetMinutes) =>
      OccurredAt(DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true), offsetMinutes);

  static final _offsetRe = RegExp(r'(Z|[+-]\d{2}:?\d{2})$');

  /// 解析 ISO-8601。必须带偏移或 Z；不带时区的字符串按 [fallbackOffsetMinutes] 解释，
  /// 未提供 fallback 则拒绝——时间歧义是记账错误的常见来源，不猜。
  factory OccurredAt.parse(String s, {int? fallbackOffsetMinutes}) {
    final t = s.trim();
    final m = _offsetRe.firstMatch(t);
    int offset;
    DateTime utc;
    if (m == null) {
      if (fallbackOffsetMinutes == null) {
        throw FormatException('occurred_at lacks timezone offset: $s');
      }
      offset = fallbackOffsetMinutes;
      final naive = DateTime.parse(t); // 本机本地时区解释，需要修正为 fallback 偏移
      final wall = DateTime.utc(naive.year, naive.month, naive.day, naive.hour, naive.minute,
          naive.second, naive.millisecond, naive.microsecond);
      utc = wall.subtract(Duration(minutes: offset));
    } else {
      final g = m.group(1)!;
      if (g == 'Z') {
        offset = 0;
      } else {
        final sign = g[0] == '-' ? -1 : 1;
        final digits = g.substring(1).replaceAll(':', '');
        offset = sign * (int.parse(digits.substring(0, 2)) * 60 + int.parse(digits.substring(2)));
      }
      utc = DateTime.parse(t).toUtc();
    }
    return OccurredAt(utc, offset);
  }

  int get millis => utc.millisecondsSinceEpoch;

  /// 墙上时间（用 UTC 实例承载，只用于取 year/month/day/hour 等字段）。
  DateTime get wall => utc.add(Duration(minutes: offsetMinutes));

  String get offsetString {
    final sign = offsetMinutes < 0 ? '-' : '+';
    final a = offsetMinutes.abs();
    return '$sign${(a ~/ 60).toString().padLeft(2, '0')}:${(a % 60).toString().padLeft(2, '0')}';
  }

  String toIso8601String() {
    final w = wall.toIso8601String(); // ...Z
    return w.substring(0, w.length - 1) + offsetString;
  }

  /// 本地日期 yyyy-MM-dd，用于按日/月分组。
  String get localDate {
    final w = wall;
    return '${w.year.toString().padLeft(4, '0')}-${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')}';
  }

  @override
  int compareTo(OccurredAt o) => utc.compareTo(o.utc);
  @override
  bool operator ==(Object other) => other is OccurredAt && other.utc == utc && other.offsetMinutes == offsetMinutes;
  @override
  int get hashCode => Object.hash(utc, offsetMinutes);
  @override
  String toString() => toIso8601String();
}
