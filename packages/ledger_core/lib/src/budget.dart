import 'db/database.dart';
import 'errors.dart';
import 'ids.dart';
import 'ledger.dart';
import 'models/enums.dart';
import 'money.dart';

enum BudgetPeriod { weekly, monthly, quarterly, yearly }

/// 预算（§5.6）。category_id 为空 = 总支出预算。
class Budget {
  final String id;
  final String name;
  final String? categoryId;
  final int amountMinor;
  final String currency;
  final BudgetPeriod period;
  final String startDate;
  final String? endDate;
  final double alertThreshold;
  final bool isActive;

  const Budget({
    required this.id,
    required this.name,
    this.categoryId,
    required this.amountMinor,
    required this.currency,
    required this.period,
    required this.startDate,
    this.endDate,
    required this.alertThreshold,
    required this.isActive,
  });

  factory Budget.fromRow(Map<String, Object?> r) => Budget(
        id: r['id'] as String,
        name: r['name'] as String,
        categoryId: r['category_id'] as String?,
        amountMinor: r['amount_minor'] as int,
        currency: r['currency'] as String,
        period: BudgetPeriod.values.byName(r['period'] as String),
        startDate: r['start_date'] as String,
        endDate: r['end_date'] as String?,
        alertThreshold: (r['alert_threshold'] as num).toDouble(),
        isActive: (r['is_active'] as int) == 1,
      );
}

class BudgetStatus {
  final Budget budget;
  final String from;
  final String to;
  final int spentMinor;
  const BudgetStatus({required this.budget, required this.from, required this.to, required this.spentMinor});
  int get remainingMinor => budget.amountMinor - spentMinor;
  double get ratio => budget.amountMinor == 0 ? 0 : spentMinor / budget.amountMinor;
  bool get overAlert => ratio >= budget.alertThreshold;
  bool get exceeded => spentMinor > budget.amountMinor;
}

class BudgetStore {
  final Ledger ledger;
  final LedgerDatabase _db;
  final int Function() _nowMs;
  BudgetStore(this.ledger, this._db, this._nowMs);

  Budget create({
    required String name,
    String? categoryId,
    required int amountMinor,
    String currency = 'CNY',
    BudgetPeriod period = BudgetPeriod.monthly,
    required String startDate,
    String? endDate,
    double alertThreshold = 0.8,
  }) {
    if (name.trim().isEmpty) throw ValidationException('name', 'required');
    if (amountMinor <= 0) throw ValidationException('amount_minor', 'must be > 0');
    if (!Currency.isKnown(currency)) throw ValidationException('currency', 'unknown');
    if (categoryId != null && ledger.category(categoryId) == null) throw NotFoundException('category', categoryId);
    if (alertThreshold <= 0 || alertThreshold > 1) throw ValidationException('alert_threshold', '0-1');
    final id = Ulid.next();
    final ts = _nowMs();
    _db.execute(
      'INSERT INTO budgets(id,name,category_id,amount_minor,currency,period,start_date,end_date,alert_threshold,is_active,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,1,?,?)',
      [id, name.trim(), categoryId, amountMinor, currency, period.name, startDate, endDate, alertThreshold, ts, ts],
    );
    return get(id);
  }

  Budget get(String id) {
    final r = _db.select('SELECT * FROM budgets WHERE id = ?', [id]);
    if (r.isEmpty) throw NotFoundException('budget', id);
    return Budget.fromRow(r.first);
  }

  List<Budget> list({bool activeOnly = true}) =>
      _db.select('SELECT * FROM budgets ${activeOnly ? 'WHERE is_active = 1' : ''} ORDER BY created_at').map(Budget.fromRow).toList();

  void update(String id, {int? amountMinor, double? alertThreshold, bool? isActive, String? name}) {
    final b = get(id);
    _db.execute('UPDATE budgets SET amount_minor=?, alert_threshold=?, is_active=?, name=?, updated_at=? WHERE id=?',
        [amountMinor ?? b.amountMinor, alertThreshold ?? b.alertThreshold, (isActive ?? b.isActive) ? 1 : 0, name ?? b.name, _nowMs(), id]);
  }

  void delete(String id) {
    get(id);
    _db.execute('DELETE FROM budgets WHERE id = ?', [id]);
  }

  /// 当前周期的执行情况。周期按 startDate 对齐：月度 = 每月同日起，周 = 每 7 天起。
  BudgetStatus status(String id, {required String today}) {
    final b = get(id);
    final (from, to) = periodRange(b, today);
    return BudgetStatus(budget: b, from: from, to: to, spentMinor: _spent(b, from, to));
  }

  List<BudgetStatus> statuses({required String today}) => [for (final b in list()) status(b.id, today: today)];

  static (String, String) periodRange(Budget b, String today) {
    DateTime parse(String s) {
      final p = s.split('-').map(int.parse).toList();
      return DateTime.utc(p[0], p[1], p[2]);
    }

    String fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final start = parse(b.startDate);
    final t = parse(today);
    switch (b.period) {
      case BudgetPeriod.weekly:
        final days = t.difference(start).inDays;
        final from = start.add(Duration(days: (days ~/ 7) * 7));
        return (fmt(from), fmt(from.add(const Duration(days: 6))));
      case BudgetPeriod.monthly:
      case BudgetPeriod.quarterly:
        final step = b.period == BudgetPeriod.monthly ? 1 : 3;
        var from = start;
        while (true) {
          final next = _addMonths(from, step, start.day);
          if (next.isAfter(t)) return (fmt(from), fmt(next.subtract(const Duration(days: 1))));
          from = next;
        }
      case BudgetPeriod.yearly:
        var from = start;
        while (true) {
          final next = _addMonths(from, 12, start.day);
          if (next.isAfter(t)) return (fmt(from), fmt(next.subtract(const Duration(days: 1))));
          from = next;
        }
    }
  }

  static DateTime _addMonths(DateTime d, int months, int anchorDay) {
    final m = d.month + months;
    final y = d.year + (m - 1) ~/ 12;
    final mm = (m - 1) % 12 + 1;
    final last = DateTime.utc(y, mm + 1, 0).day;
    return DateTime.utc(y, mm, anchorDay > last ? last : anchorDay);
  }

  int _spent(Budget b, String from, String to) {
    Set<String>? cats;
    if (b.categoryId != null) {
      cats = {b.categoryId!};
      final all = ledger.listCategories();
      var grew = true;
      while (grew) {
        grew = false;
        for (final c in all) {
          if (c.parentId != null && cats.contains(c.parentId) && cats.add(c.id)) grew = true;
        }
      }
    }
    final fromUtc = DateTime.parse('${from}T00:00:00Z').subtract(const Duration(days: 1));
    final toUtc = DateTime.parse('${to}T00:00:00Z').add(const Duration(days: 2));
    var sum = 0;
    for (final t in ledger.listTransactions(from: fromUtc, to: toUtc, limit: 1 << 30)) {
      if (t.currency != b.currency) continue;
      final d = t.occurredAt.localDate;
      if (d.compareTo(from) < 0 || d.compareTo(to) > 0) continue;
      if (cats != null && !cats.contains(t.categoryId)) continue;
      if (t.type == TransactionType.expense) sum += t.amountMinor;
      if (t.type == TransactionType.refund) sum -= t.amountMinor;
    }
    return sum;
  }
}
