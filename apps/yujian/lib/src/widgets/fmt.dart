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
