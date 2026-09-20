import 'debts.dart';
import 'ledger.dart';
import 'models/account.dart';
import 'models/enums.dart';
import 'money.dart';
import 'models/transaction.dart';

/// 收入线：主线（工资 / 奖金）、副本（兼职 / 礼金 / 外快）、挂机（利息 / 分红 / 理财收益）。
enum IncomeLine { main, side, passive, other }

/// 财富等级：只是给「生存月数」起的名字。[name] 是等级名（讲进度用），[title] 是称号（首页 / 桌面小部件上挂的身份，
/// 直白但不骂人：最穷是「贫困户」，往上月光族 → 温饱户 → 小康 → 中产 → 人上人）。净资产为负时称号换成 [DebtTier] 那套。
class WealthLevel {
  final int index; // 0..5
  final String name;
  final String title;
  final double minMonths;
  final double? maxMonths;
  const WealthLevel(this.index, this.name, this.title, this.minMonths, this.maxMonths);

  static const levels = [
    WealthLevel(0, '起步', '贫困户', 0, 0.5),
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

/// 负翁档：净资产（资产 − 负债）是负的时候挂的称号，按欠的金额分档（等级仍按生存月数算，只是称号换成这套）。
/// 「富翁」的反面：小负翁（欠不到 1 万）→ 负翁（1 万起）→ 大负翁（10 万起）→ 百万负翁 → 千万负翁。
/// [floorMinor] 是这一档的起点（欠款 ≥ 它才算），还到低于它就降一档；最轻一档的起点是 0：还清就回到「贫困户」起步。
class DebtTier {
  final int index; // 0 = 最轻
  final String title;
  final int floorMinor;
  const DebtTier(this.index, this.title, this.floorMinor);

  static const tiers = [
    DebtTier(0, '小负翁', 0),
    DebtTier(1, '负翁', 1000000),
    DebtTier(2, '大负翁', 10000000),
    DebtTier(3, '百万负翁', 100000000),
    DebtTier(4, '千万负翁', 1000000000),
  ];

  /// [debtMinor] 是净负债（正数，= −净资产）。
  static DebtTier of(int debtMinor) {
    for (final t in tiers.reversed) {
      if (debtMinor >= t.floorMinor) return t;
    }
    return tiers.first;
  }

  /// 轻一档；最轻一档没有（再还就是净资产转正）。
  DebtTier? get lighter => index > 0 ? tiers[index - 1] : null;
}

/// 「月支出」是按什么估的：手填 > 历史整月均值 > 近 31 天收入（先按月光算）> 本月按天外推 > 周期账单合计 > 没数据。
/// 目的：用户录完第一批账就能有等级 / 称号，不用等记满一个月；财富页把依据写出来。
enum SpendBasis { manual, history, thisMonth, recurring, income, none }

/// 财富指标：全部从账本推导，不落库。每个字段都能在财富页解释「怎么来的」。
class WealthMetrics {
  final String today;
  final String currency;
  final int liquidMinor; // 流动资产：cash + bank + e_wallet + vault（正数部分）
  final int lockedMinor; // 各目标锁仓里的钱
  final int fixedDueMinor; // 到发薪日前还要付的固定支出 + 还贷（周期账单里 next_due 在此之前的支出模板、转到贷款账户的转账模板）
  final int cardOwedMinor; // 信用卡待还（刷了就扣，还卡时不再扣）
  final int disposableMinor; // 可花的 = liquid − locked − fixedDue − cardOwed
  final String payday; // 下个发薪日 yyyy-MM-dd
  final String paydaySource; // profile | inferred | month_end
  final int daysToPayday; // ≥ 1
  final int spentTodayMinor;
  final int dailyAllowanceMinor; // 今天还能花 = disposable ÷ daysToPayday（可花的已经是扣掉今天支出之后的数，不再减一次）
  final int monthlySpendAvgMinor; // 月支出基线（含每月还贷）；按 spendBasis 估
  final SpendBasis spendBasis;
  final int monthsOfData; // 有支出记录的整月数（≤ 3）
  final double? runwayMonths; // 生存月数 = 流动资产 ÷ 月支出基线；没有任何依据 = null
  final WealthLevel? level;
  final int? toNextLevelMinor; // 升到下一级还差多少流动资产
  final int monthIncomeMinor;
  final int monthExpenseMinor;
  final double? savingsRate; // (收入 − 支出) / 收入；收入 0 = null
  final int netWorthMinor; // 全部账户余额之和（信用卡 / 应付为负）= assets − debt
  final int assetsMinor; // 正余额账户之和（含锁仓、投资）
  final DebtTotals debt; // 贷款 / 信用卡 / 每月还款 合计
  final int repaymentMonthlyMinor; // 每月要还的贷款（周期转账月度化），等级口径里算进月支出
  final Map<IncomeLine, int> incomeByLine; // 本月
  final List<Account> excludedForeign; // 币种不同没算进去的账户

  const WealthMetrics({
    required this.today,
    required this.currency,
    required this.liquidMinor,
    required this.lockedMinor,
    required this.fixedDueMinor,
    required this.cardOwedMinor,
    required this.disposableMinor,
    required this.payday,
    required this.paydaySource,
    required this.daysToPayday,
    required this.spentTodayMinor,
    required this.dailyAllowanceMinor,
    required this.monthlySpendAvgMinor,
    required this.spendBasis,
    required this.monthsOfData,
    required this.runwayMonths,
    required this.level,
    required this.toNextLevelMinor,
    required this.monthIncomeMinor,
    required this.monthExpenseMinor,
    required this.savingsRate,
    required this.netWorthMinor,
    required this.assetsMinor,
    required this.debt,
    required this.repaymentMonthlyMinor,
    required this.incomeByLine,
    required this.excludedForeign,
  });

  /// 净资产是负的（负债比资产多）。
  bool get inDebt => netWorthMinor < 0;

  /// 负翁档：只在净资产为负时有；按欠的金额（−净资产）分。
  DebtTier? get debtTier => inDebt ? DebtTier.of(-netWorthMinor) : null;

  /// 称号：净资产为负 → 负翁那套（按欠款），否则按生存月数的等级称号；两边都没依据 = null。
  String? get title => debtTier?.title ?? level?.title;

  /// 负翁想降一档要再还多少：还到低于这档起点就降；最轻一档 = 还清（净资产转正）。不在负翁档 = null。
  int? get toLighterDebtTierMinor {
    final t = debtTier;
    if (t == null) return null;
    final debt = -netWorthMinor;
    return t.lighter == null ? debt : debt - t.floorMinor + 1;
  }
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
    var assets = 0;
    var cardOwed = 0;
    for (final a in accounts) {
      if (a.currency != currency) {
        foreign.add(a);
        continue;
      }
      final b = ledger.balance(a.id).minor;
      netWorth += b;
      if (b > 0) assets += b;
      if (_liquidTypes.contains(a.type) && b > 0) liquid += b;
      if (a.type == AccountType.creditCard && b < 0) cardOwed += -b;
    }
    var locked = 0;
    for (final g in ledger.goals.list()) {
      if (g.currency == currency) locked += ledger.goals.savedMinor(g);
    }
    final debts = ledger.debts;
    final debtTotals = debts.totals(currency: currency);

    // 发薪日
    final (payday, source) = nextPayday(today: today);
    final pd = _parse(payday);
    final days = pd.difference(t).inDays.clamp(1, 366);

    // 到发薪日前要付的：支出模板 + 还贷转账模板，next_due 落在 [today, payday]
    var fixedDue = 0;
    var recurringMonthly = 0; // 每月固定支出 + 还贷（月度化），本月外推时的下限
    for (final r in ledger.recurring.list()) {
      if (!r.isActive) continue;
      if ((r.template['currency'] ?? currency) != currency) continue;
      final isExpense = r.template['type'] == 'expense';
      final isRepay = debts.isRepayment(r);
      if (!isExpense && !isRepay) continue;
      recurringMonthly += Debts.monthly(r);
      if (r.nextDue.compareTo(today) < 0 || r.nextDue.compareTo(payday) > 0) continue;
      fixedDue += ((r.template['amount_minor'] as num?)?.toInt() ?? 0);
    }
    final disposable = liquid - locked - fixedDue - cardOwed;

    // 今天已花（只是展示）；今天还能花 = 可花的 ÷ 到发薪日的天数——可花的来自余额，已经扣过今天的支出，不再减一次
    final spentToday = _expense(from: today, to: today, currency: currency);
    final daily = disposable <= 0 ? 0 : (disposable / days).floor();

    // 月支出基线：历史整月（近 3 个月，当月不算）
    var months = 0;
    var spendSum = 0;
    for (var i = 1; i <= 3; i++) {
      final m = DateTime.utc(t.year, t.month - i, 1);
      final last = DateTime.utc(m.year, m.month + 1, 0);
      final s = _outflow(from: _fmt(m), to: _fmt(last), currency: currency);
      if (s > 0) {
        months++;
        spendSum += s;
      }
    }
    final m0 = DateTime.utc(t.year, t.month, 1);
    final mEnd = DateTime.utc(t.year, t.month + 1, 0);
    var basis = SpendBasis.none;
    var baseline = 0;
    final manual = profile.monthlyCostMinor;
    if (manual != null) {
      basis = SpendBasis.manual;
      baseline = manual;
    } else if (months > 0) {
      basis = SpendBasis.history;
      baseline = spendSum ~/ months;
    } else {
      // 近 31 天有收入：先按收入当月支出（月光算法）。第一个月只记了几笔支出就按天外推会得出「一个月花 96 块、够花 103 个月、人上人」
      // 这种笑话；按收入估至少是个保守的整数。记满一个整月就换成真实均值，嫌不准可以手填
      var recentIncome = 0;
      for (final tx in _range(from: _fmt(t.subtract(const Duration(days: 30))), to: today, currency: currency)) {
        if (tx.type == TransactionType.income) recentIncome += tx.amountMinor;
      }
      // 没收入记录：本月按天外推（至少 3 天才外推，1–2 天的数据太抖），周期账单合计当下限
      final thisMonth = _outflow(from: _fmt(m0), to: today, currency: currency);
      final elapsed = t.day;
      final extrapolated = elapsed >= 3 && thisMonth > 0 ? (thisMonth * mEnd.day / elapsed).round() : 0;
      if (recentIncome > 0) {
        basis = SpendBasis.income;
        baseline = recentIncome;
      } else if (extrapolated > 0) {
        basis = SpendBasis.thisMonth;
        baseline = extrapolated > recurringMonthly ? extrapolated : recurringMonthly;
      } else if (recurringMonthly > 0) {
        basis = SpendBasis.recurring;
        baseline = recurringMonthly;
      }
    }
    final runway = baseline <= 0 ? null : liquid / baseline;
    final level = runway == null ? null : WealthLevel.of(runway);
    int? toNext;
    if (level?.next != null && baseline > 0) toNext = ((level!.next!.minMonths * baseline) - liquid).ceil().clamp(0, maxMinor);

    // 本月收入 / 支出 / 收入线
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
      cardOwedMinor: cardOwed,
      disposableMinor: disposable,
      payday: payday,
      paydaySource: source,
      daysToPayday: days,
      spentTodayMinor: spentToday,
      dailyAllowanceMinor: daily,
      monthlySpendAvgMinor: baseline,
      spendBasis: basis,
      monthsOfData: months,
      runwayMonths: runway,
      level: level,
      toNextLevelMinor: toNext,
      monthIncomeMinor: income,
      monthExpenseMinor: expense,
      savingsRate: savingsRate,
      netWorthMinor: netWorth,
      assetsMinor: assets,
      debt: debtTotals,
      repaymentMonthlyMinor: debtTotals.monthlyMinor,
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

  /// 一段日期内的现金流出 = 净支出 + 还贷（从流动账户转到贷款账户的转账）。等级的「月支出」按它算：
  /// 房贷车贷每月真金白银出去了，生存月数不能装作没有。信用卡还款不算（刷卡消费已经是支出，再算一次就重了）。
  int _outflow({required String from, required String to, required String currency}) {
    var sum = _expense(from: from, to: to, currency: currency);
    for (final tx in _range(from: from, to: to, currency: currency)) {
      if (tx.type != TransactionType.transfer) continue;
      final toA = ledger.account(tx.toAccountId ?? '');
      if (toA == null || toA.type != AccountType.payable) continue;
      final fromA = ledger.account(tx.accountId);
      if (fromA != null && !_liquidTypes.contains(fromA.type)) continue;
      sum += tx.amountMinor;
    }
    return sum;
  }

  static DateTime _parse(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
