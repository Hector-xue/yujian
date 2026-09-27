import 'package:ledger_core/ledger_core.dart';

/// 金额：负号放最前面（-¥12.00），全 App 一个写法（以前负数是「¥-12.00」，有的页面又自己拼「−¥」）。
String fmtMoney(int minor, String currency) {
  final s = Money(minor < 0 ? -minor : minor, currency).toDecimalString();
  final sign = minor < 0 ? '-' : '';
  return currency == 'CNY' ? '$sign¥$s' : '$sign$s $currency';
}

/// 短日期：「10/1」；不是今年的带上年份「2027/4/1」。全 App 的日子都用它（以前 10/01、10/1、2026-10-01、09/21 混着用）。
String fmtMd(String localDate, {String? today}) {
  final p = localDate.split('-');
  if (p.length < 3) return localDate;
  final md = '${int.parse(p[1])}/${int.parse(p[2].substring(0, 2))}';
  final thisYear = (today ?? todayLocal()).substring(0, 4);
  return p[0] == thisYear ? md : '${p[0]}/$md';
}

String fmtSigned(Transaction t) {
  final v = fmtMoney(t.amountMinor, t.currency);
  return switch (t.type) {
    TransactionType.expense => '-$v',
    TransactionType.income || TransactionType.refund => '+$v',
    _ => v,
  };
}

String typeLabel(String type) => switch (type) {
      'expense' => '支出',
      'income' => '收入',
      'transfer' => '转账',
      'refund' => '退款',
      'adjustment' => '调整',
      _ => type,
    };

String fmtDate(String localDate, {String? today}) {
  if (localDate == today) return '今天';
  final parts = localDate.split('-');
  return '${int.parse(parts[1])}月${int.parse(parts[2])}日';
}

String todayLocal() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

/// 毫秒时间戳 → 「刚刚 / 3 分钟前 / 2 小时前 / 昨天 14:05 / 9/12 14:05」。
String fmtRelativeMs(int ms, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final diff = n.difference(t);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && t.day == n.day) return '${diff.inHours} 小时前';
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final yesterday = DateTime(n.year, n.month, n.day - 1);
  if (t.year == yesterday.year && t.month == yesterday.month && t.day == yesterday.day) return '昨天 $hm';
  return '${t.month}/${t.day} $hm';
}
