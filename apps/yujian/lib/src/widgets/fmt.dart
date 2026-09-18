import 'package:ledger_core/ledger_core.dart';

String fmtMoney(int minor, String currency) {
  final m = Money(minor, currency);
  final s = m.toDecimalString();
  return currency == 'CNY' ? '¥$s' : '$s $currency';
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
