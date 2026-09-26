import 'cards.dart';
import 'ledger.dart';
import 'models/enums.dart';
import 'models/transaction.dart';

/// 发薪日是从哪来的。
enum PaydaySource { profile, inferred, monthEnd }

/// 每月哪几天发薪（工资、绩效分开发就是两天），和它是怎么定的。
class PaydaySchedule {
  final List<int> days; // 1–31，升序；空 = 不知道（按月底估）
  final PaydaySource source;
  const PaydaySchedule(this.days, this.source);
}

/// 下一次发薪。
class NextPayday {
  final String date; // yyyy-MM-dd
  final PaydaySource source;
  final String? lateSince; // 本该在这天到、到现在还没到的那一期；非空时 [date] 是「按明天会到」估的
  const NextPayday(this.date, this.source, {this.lateSince});
  bool get isLate => lateSince != null;
}

/// 发薪日：所有用到它的地方（可花的、日历、还款计划、发薪日仪式）都走这里，口径只有一个。
///
/// - 填了用填的（可以几个），没填从收入记录推（能推出工资、绩效两个日子），推不出按月底估；
/// - 推断永远站在「真正的今天」看收入记录：以前日历从「这个月的前一天」往后推，看不到本月的工资，退回月底；
/// - 看这一期到底到没到：提前到了（周末提前发）这一期就算发过了；晚了（上个月这一期有进账、这个月过了日子还没到）
///   按明天会到估，页面上写「工资还没到」——以前只认几号，早到一天整月的钱按 1 天分，晚到一天又按 30 天分。
class Paydays {
  final Ledger ledger;
  Paydays(this.ledger);

  static const earlyDays = 3; // 最多提前几天到账还算这一期
  static const lateDays = 7; // 过了日子几天内没到算「晚了」，再往后就当这期没了

  PaydaySchedule schedule({required String today}) {
    final set = ledger.profile.paydays;
    if (set.isNotEmpty) return PaydaySchedule(set, PaydaySource.profile);
    final inferred = infer(today: today);
    return inferred.isEmpty ? const PaydaySchedule([], PaydaySource.monthEnd) : PaydaySchedule([...inferred]..sort(), PaydaySource.inferred);
  }

  /// [from]–[to]（含）里的发薪日（按 [today] 那天的发薪安排推）。推不出发薪日时是每月最后一天（估的）。
  List<String> occurrences({required String from, required String to, required String today, PaydaySchedule? schedule}) {
    final s = schedule ?? this.schedule(today: today);
    final f = _parse(from), t = _parse(to);
    final out = <String>[];
    var y = f.year, m = f.month;
    while (!DateTime.utc(y, m, 1).isAfter(t)) {
      final last = DateTime.utc(y, m + 1, 0).day;
      final days = s.days.isEmpty ? [last] : s.days;
      for (final d in days.map((d) => d > last ? last : d).toSet()) {
        final date = _fmt(DateTime.utc(y, m, d));
        if (date.compareTo(from) >= 0 && date.compareTo(to) <= 0) out.add(date);
      }
      if (m == 12) {
        y++;
        m = 1;
      } else {
        m++;
      }
    }
    out.sort();
    return out;
  }

  /// 下一次发薪（今天之后；这一期晚了的话是明天）。
  NextPayday next({required String today}) {
    final s = schedule(today: today);
    final occ = occurrences(from: CreditCards.addDays(today, -40), to: CreditCards.addDays(today, 80), today: today, schedule: s);
    if (s.days.isEmpty) {
      return NextPayday(occ.firstWhere((d) => d.compareTo(today) > 0), PaydaySource.monthEnd);
    }
    for (final o in occ) {
      if (o.compareTo(today) <= 0) {
        // 过了日子：这一期到了吗？没到、没晚太久、而且上个月这一期确实有进账（不记工资的人不算「晚了」）→ 按明天会到
        final since = CreditCards.daysBetween(o, today);
        if (since <= lateDays && !_received(CreditCards.addDays(o, -earlyDays), today) && _received(CreditCards.addDays(_monthBefore(o), -earlyDays), CreditCards.addDays(_monthBefore(o), lateDays))) {
          return NextPayday(CreditCards.addDays(today, 1), s.source, lateSince: o);
        }
        continue;
      }
      // 还没到日子：已经提前到账了（周末提前发）→ 这一期算发过了
      if (CreditCards.daysBetween(today, o) <= earlyDays && _received(CreditCards.addDays(o, -earlyDays), today)) continue;
      return NextPayday(o, s.source);
    }
    return NextPayday(occ.last, s.source);
  }

  /// 今天是不是发薪日（发薪日仪式按工资估的那张卡用）。
  bool isPayday({required String today}) {
    final s = schedule(today: today);
    return s.days.isNotEmpty && occurrences(from: today, to: today, today: today, schedule: s).isNotEmpty;
  }

  /// 这一期大概到账多少：近 3 个月同一期（同一个发薪日前后）实际进账的中位数；没有记录 = null。
  int? expectedIncome(String occurrence) {
    final amounts = <int>[];
    var o = occurrence;
    for (var k = 0; k < 3; k++) {
      o = _monthBefore(o);
      final got = _slotIncome(CreditCards.addDays(o, -earlyDays), CreditCards.addDays(o, lateDays));
      if (got > 0) amounts.add(got);
    }
    if (amounts.isEmpty) return null;
    amounts.sort();
    return amounts[amounts.length ~/ 2];
  }

  /// 从收入记录推发薪日（最多两个）：
  /// 主日子——每个月取一笔代表（有工资 / 奖金取其中最大的，没有取最大的一笔收入），日子取众数；
  /// 第二个——别的工资 / 奖金（比如绩效）连续两三个月落在另一个日子（前后 2 天内算同一个），就也算一个发薪日。
  List<int> infer({required String today}) {
    final t = _parse(today);
    final primaryDays = <int>[];
    final others = <List<int>>[]; // 每个整月里除主工资外的工资 / 奖金日子
    for (final i in const [1, 2, 3, 0]) {
      final m = DateTime.utc(t.year, t.month - i, 1);
      final last = DateTime.utc(m.year, m.month + 1, 0);
      final incomes = [for (final tx in _incomes(_fmt(m), _fmt(last))) tx];
      Transaction? salary;
      Transaction? any;
      for (final tx in incomes) {
        if (_isPayCategory(tx) && (salary == null || tx.amountMinor > salary.amountMinor)) salary = tx;
        if (any == null || tx.amountMinor > any.amountMinor) any = tx;
      }
      final best = salary ?? (i == 0 ? null : any);
      if (best != null) primaryDays.add(_day(best));
      if (i > 0 && salary != null) {
        others.add([
          for (final tx in incomes)
            if (_isPayCategory(tx) && tx.id != salary.id && tx.amountMinor * 10 >= salary.amountMinor) _day(tx),
        ]);
      }
    }
    if (primaryDays.isEmpty) return const [];
    final counts = <int, int>{};
    for (final d in primaryDays) {
      counts[d] = (counts[d] ?? 0) + 1;
    }
    var primary = primaryDays.first;
    for (final d in primaryDays) {
      if (counts[d]! > counts[primary]!) primary = d; // 严格大于：平票保留更近的整月
    }
    // 第二个日子：离主日子 3 天以上、在至少两个整月里出现（±2 天）
    int? second;
    var bestHits = 1;
    for (final month in others) {
      for (final d in month) {
        if ((d - primary).abs() < 3) continue;
        final hits = others.where((m2) => m2.any((x) => (x - d).abs() <= 2)).length;
        if (hits > bestHits) {
          bestHits = hits;
          second = d;
        }
      }
    }
    return second == null ? [primary] : [primary, second]; // 主发薪日在前（老接口 inferPaydayDay 取它）
  }

  // --------------------------------------------------------------- 内部

  bool _isPayCategory(Transaction tx) => tx.categoryId == 'salary' || tx.categoryId == 'bonus';

  /// 「像工资的进账」：工资 / 奖金分类；从来不用这两个分类的人，按「不小于近 3 个月最大一笔收入的一半」认。
  late final List<Transaction> _recentIncomes = _incomes(_fmt(ledger.now().toUtc().subtract(const Duration(days: 100))), '9999-12-31');
  late final bool _usesPayCategory = _recentIncomes.any(_isPayCategory);
  late final int _bigIncome = _recentIncomes.fold(0, (a, tx) => tx.amountMinor > a ? tx.amountMinor : a);
  bool _payLike(Transaction tx) => _usesPayCategory ? _isPayCategory(tx) : tx.amountMinor * 2 >= _bigIncome && _bigIncome > 0;

  bool _received(String from, String to) => _incomes(from, to).any(_payLike);
  int _slotIncome(String from, String to) => _incomes(from, to).where(_payLike).fold(0, (a, tx) => a + tx.amountMinor);

  List<Transaction> _incomes(String from, String to) {
    final f = _parse(from).subtract(const Duration(days: 1));
    final t = to.startsWith('9999') ? null : _parse(to).add(const Duration(days: 2));
    return [
      for (final tx in ledger.listTransactions(from: f, to: t, type: TransactionType.income, limit: 1 << 30))
        if (tx.occurredAt.localDate.compareTo(from) >= 0 && tx.occurredAt.localDate.compareTo(to) <= 0) tx,
    ];
  }

  static int _day(Transaction tx) => int.parse(tx.occurredAt.localDate.substring(8, 10));

  /// 上个月的「同一天」（没有那天按月底）。
  static String _monthBefore(String date) {
    final d = _parse(date);
    final last = DateTime.utc(d.year, d.month, 0).day;
    return _fmt(DateTime.utc(d.year, d.month - 1, d.day > last ? last : d.day));
  }

  static DateTime _parse(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
