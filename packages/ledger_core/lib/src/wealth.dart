import 'ledger.dart';
import 'models/account.dart';
import 'models/enums.dart';
import 'models/transaction.dart';

/// 收入线：主线（工资 / 奖金）、副本（兼职 / 礼金 / 外快）、挂机（利息 / 分红 / 理财收益）。
enum IncomeLine { main, side, passive, other }

/// 财富等级：只是给「生存月数」起的名字。[name] 是等级名（讲进度用），[title] 是称号（首页 / 桌面小部件上挂的身份，
/// 嘲讽但真实：最穷就是穷逼，别粉饰）。
class WealthLevel {
  final int index; // 0..5
  final String name;
  final String title;
  final double minMonths;
  final double? maxMonths;
  const WealthLevel(this.index, this.name, this.title, this.minMonths, this.maxMonths);

  static const levels = [
    WealthLevel(0, '起步', '穷逼', 0, 0.5),
    WealthLevel(1, '喘口气', '月光族', 0.5, 1),
    WealthLevel(2, '站稳', '温饱户', 1, 3),
    WealthLevel(3, '安心', '小康', 3, 6),
    WealthLevel(4, '从容', '中产', 6, 12),
    WealthLevel(5, '自由感', '人上人', 12, null),
  ];

  static WealthLevel of(double months) {
    for (final l in levels.reversed) {
      if (months >= l.minMonths) return l;
    }
    return levels.first;
  }

  WealthLevel? get next => index + 1 < levels.length ? levels[index + 1] : null;
}

/// 财富指标：全部从账本推导，不落库。每个字段都能在财富页解释「怎么来的」。
class WealthMetrics {
  final String today;
  final String currency;
  final int liquidMinor; // 流动资产：cash + bank + e_wallet + vault（正数部分）
  final int lockedMinor; // 各目标锁仓里的钱
  final int fixedDueMinor; // 到发薪日前还要付的固定支出（周期账单里 next_due 在此之前的支出模板）
  final int disposableMinor; // 可花的 = liquid − locked − fixedDue
  final String payday; // 下个发薪日 yyyy-MM-dd
  final String paydaySource; // profile | inferred | month_end
  final int daysToPayday; // ≥ 1
  final int spentTodayMinor;
  final int dailyAllowanceMinor; // 今天还能花 = disposable ÷ daysToPayday − 今天已花（不为负）
  final int monthlySpendAvgMinor; // 近 3 个月平均月支出（不足 3 个月按有的算）
  final int monthsOfData; // 有支出记录的月数（≤ 3）
  final double? runwayMonths; // 生存月数；没有月支出数据 = null
  final WealthLevel? level;
  final int? toNextLevelMinor; // 升到下一级还差多少流动资产
  final int monthIncomeMinor;
  final int monthExpenseMinor;
  final double? savingsRate; // (收入 − 支出) / 收入；收入 0 = null
  final int netWorthMinor; // 全部账户余额之和（信用卡 / 应付为负）
  final Map<IncomeLine, int> incomeByLine; // 本月
  final List<Account> excludedForeign; // 币种不同没算进去的账户

  const WealthMetrics({
    required this.today,
    required this.currency,
    required this.liquidMinor,
    required this.lockedMinor,
    required this.fixedDueMinor,
    required this.disposableMinor,
    required this.payday,
    required this.paydaySource,
    required this.daysToPayday,
    required this.spentTodayMinor,
    required this.dailyAllowanceMinor,
    required this.monthlySpendAvgMinor,
    required this.monthsOfData,
    required this.runwayMonths,
    required this.level,
    required this.toNextLevelMinor,
    required this.monthIncomeMinor,
    required this.monthExpenseMinor,
    required this.savingsRate,
    required this.netWorthMinor,
    required this.incomeByLine,
    required this.excludedForeign,
  });
}

/// 指标计算。调用方（App）在账本变更后算一次并缓存，页面只读缓存——别在 build 里调。
class Wealth {
  final Ledger ledger;
  Wealth(this.ledger);

  static const _liquidTypes = {AccountType.cash, AccountType.bank, AccountType.eWallet, AccountType.vault};

  /// 收入分类 → 收入线。画像里可覆盖；默认按内置分类。
  static IncomeLine lineOf(String? categoryId, Map<String, String> overrides) {
    if (categoryId == null) return IncomeLine.other;
    final o = overrides[categoryId];
    if (o != null) return IncomeLine.values.asNameMap()[o] ?? IncomeLine.other;
    return switch (categoryId) {
      'salary' || 'bonus' => IncomeLine.main,
      'parttime' || 'gift' => IncomeLine.side,
      'investment_income' => IncomeLine.passive,
      _ => IncomeLine.other,
    };
  }

  WealthMetrics compute({required String today, String currency = 'CNY'}) {
    final t = _parse(today);
    final profile = ledger.profile;
    final accounts = ledger.listAccounts(includeVault: true);
    final foreign = <Account>[];
    var liquid = 0;
    var netWorth = 0;
    for (final a in accounts) {
      if (a.currency != currency) {
        foreign.add(a);
        continue;
      }
      final b = ledger.balance(a.id).minor;
      netWorth += b;
      if (_liquidTypes.contains(a.type) && b > 0) liquid += b;
    }
    var locked = 0;
    for (final g in ledger.goals.list()) {
      if (g.currency == currency) locked += ledger.goals.savedMinor(g);
    }

    // 发薪日
    final (payday, source) = nextPayday(today: today);
    final pd = _parse(payday);
    final days = pd.difference(t).inDays.clamp(1, 366);

    // 到发薪日前的固定支出：周期账单里的支出模板，next_due 落在 (today, payday]
    var fixedDue = 0;
    for (final r in ledger.recurring.list()) {
      if (!r.isActive) continue;
      if (r.template['type'] != 'expense') continue;
      if ((r.template['currency'] ?? currency) != currency) continue;
      if (r.nextDue.compareTo(today) < 0 || r.nextDue.compareTo(payday) > 0) continue;
      fixedDue += ((r.template['amount_minor'] as num?)?.toInt() ?? 0);
    }
    final disposable = liquid - locked - fixedDue;

    // 今天已花
    final spentToday = _expense(from: today, to: today, currency: currency);
    final dailyRaw = disposable <= 0 ? 0 : (disposable / days).floor();
    final daily = (dailyRaw - spentToday).clamp(0, 1 << 62);

    // 近 3 个月平均月支出（当月不算，不满一个月的数据不稳）
    var months = 0;
    var spendSum = 0;
    for (var i = 1; i <= 3; i++) {
      final m = DateTime.utc(t.year, t.month - i, 1);
      final last = DateTime.utc(m.year, m.month + 1, 0);
      final s = _expense(from: _fmt(m), to: _fmt(last), currency: currency);
      if (s > 0) {
        months++;
        spendSum += s;
      }
    }
    final avg = months == 0 ? 0 : spendSum ~/ months;
    final runway = avg == 0 ? null : liquid / avg;
    final level = runway == null ? null : WealthLevel.of(runway);
    int? toNext;
    if (level?.next != null && avg > 0) toNext = ((level!.next!.minMonths * avg) - liquid).ceil().clamp(0, 1 << 62);

    // 本月收入 / 支出 / 收入线
    final m0 = DateTime.utc(t.year, t.month, 1);
    final mEnd = DateTime.utc(t.year, t.month + 1, 0);
    final overrides = profile.incomeLines;
    final byLine = {for (final l in IncomeLine.values) l: 0};
    var income = 0;
    for (final tx in _range(from: _fmt(m0), to: _fmt(mEnd), currency: currency)) {
      if (tx.type == TransactionType.income) {
        income += tx.amountMinor;
        final l = lineOf(tx.categoryId, overrides);
        byLine[l] = byLine[l]! + tx.amountMinor;
      }
    }
    final expense = _expense(from: _fmt(m0), to: _fmt(mEnd), currency: currency);
    final savingsRate = income == 0 ? null : (income - expense) / income;

    return WealthMetrics(
      today: today,
      currency: currency,
      liquidMinor: liquid,
      lockedMinor: locked,
      fixedDueMinor: fixedDue,
      disposableMinor: disposable,
      payday: payday,
      paydaySource: source,
      daysToPayday: days,
      spentTodayMinor: spentToday,
      dailyAllowanceMinor: daily,
      monthlySpendAvgMinor: avg,
      monthsOfData: months,
      runwayMonths: runway,
      level: level,
      toNextLevelMinor: toNext,
      monthIncomeMinor: income,
      monthExpenseMinor: expense,
      savingsRate: savingsRate,
      netWorthMinor: netWorth,
      incomeByLine: byLine,
      excludedForeign: foreign,
    );
  }

  /// 下一个发薪日：画像里填了按画像；没填从最近 3 个月里最大的那笔收入推日子；推不出按月底。
  (String, String) nextPayday({required String today}) {
    final t = _parse(today);
    final day = ledger.profile.payday ?? inferPaydayDay(today: today);
    final source = ledger.profile.payday != null ? 'profile' : (day != null ? 'inferred' : 'month_end');
    if (day == null) {
      final end = DateTime.utc(t.year, t.month + 1, 0);
      final next = end.isAfter(t) ? end : DateTime.utc(t.year, t.month + 2, 0);
      return (_fmt(next), source);
    }
    DateTime candidate(int y, int m) {
      final last = DateTime.utc(y, m + 1, 0).day;
      return DateTime.utc(y, m, day > last ? last : day);
    }

    var c = candidate(t.year, t.month);
    if (!c.isAfter(t)) c = candidate(t.year, t.month + 1);
    return (_fmt(c), source);
  }

  /// 从收入记录推发薪日：最近 3 个月每月最大的一笔收入（工资 / 奖金分类优先），日子取众数。
  int? inferPaydayDay({required String today}) {
    final t = _parse(today);
    final days = <int>[];
    for (var i = 0; i < 3; i++) {
      final m = DateTime.utc(t.year, t.month - i, 1);
      final last = DateTime.utc(m.year, m.month + 1, 0);
      Transaction? best;
      for (final tx in _range(from: _fmt(m), to: _fmt(last))) {
        if (tx.type != TransactionType.income) continue;
        final salaryish = tx.categoryId == 'salary' || tx.categoryId == 'bonus';
        if (best == null || (salaryish && !(best.categoryId == 'salary' || best.categoryId == 'bonus')) || tx.amountMinor > best.amountMinor) best = tx;
      }
      if (best != null) days.add(int.parse(best.occurredAt.localDate.substring(8, 10)));
    }
    if (days.isEmpty) return null;
    final counts = <int, int>{};
    for (final d in days) {
      counts[d] = (counts[d] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  List<Transaction> _range({required String from, required String to, String? currency}) {
    final f = _parse(from).subtract(const Duration(days: 1));
    final tt = _parse(to).add(const Duration(days: 2));
    return [
      for (final tx in ledger.listTransactions(from: f, to: tt, limit: 1 << 30))
        if (tx.occurredAt.localDate.compareTo(from) >= 0 && tx.occurredAt.localDate.compareTo(to) <= 0 && (currency == null || tx.currency == currency)) tx,
    ];
  }

  /// 一段日期内的净支出（支出 − 退款），锁仓账户之间的转账不算。
  int _expense({required String from, required String to, required String currency}) {
    var sum = 0;
    for (final tx in _range(from: from, to: to, currency: currency)) {
      if (tx.type == TransactionType.expense) sum += tx.amountMinor;
      if (tx.type == TransactionType.refund) sum -= tx.amountMinor;
    }
    return sum;
  }

  static DateTime _parse(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
