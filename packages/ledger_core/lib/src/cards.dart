import 'dart:convert';

import 'ledger.dart';
import 'models/account.dart';
import 'models/enums.dart';

/// 利息怎么算：
/// - full 全额计息：没还清就整笔账单从每笔消费的记账日起按日计息（多数股份制银行信用卡）；
/// - unpaid 未还部分计息：到期前按「没还的比例」计（部分国有行）；
/// - afterDue 到期后才计息：按时还清不收利息，逾期后只对没还的部分按日计息（花呗、抖音月付这一类）；
/// - daily 按天计息：从用的那天起每天计息，按时还也有利息（微信分付：当天借当天还不计息，借一天算一天）。
/// 拿不准看账单页 / 合约；信用卡拿不准选全额——算出来只会多不会少。
enum CardInterestMode { full, unpaid, afterDue, daily }

/// 哪一类信用产品：只决定图标、默认名字和默认条款（都能改）。
enum CreditProduct { bank, huabei, fenfu, baitiao, douyin }

extension CreditProductX on CreditProduct {
  String get label => switch (this) {
        CreditProduct.bank => '信用卡',
        CreditProduct.huabei => '花呗',
        CreditProduct.fenfu => '微信分付',
        CreditProduct.baitiao => '京东白条',
        CreditProduct.douyin => '抖音月付',
      };

  String get emoji => switch (this) {
        CreditProduct.bank => '💳',
        CreditProduct.huabei => '🌸',
        CreditProduct.fenfu => '💚',
        CreditProduct.baitiao => '🐶',
        CreditProduct.douyin => '🎵',
      };

  /// 常见的「账单日 → 还款日」组合（各家 App 里能选的那几档）；第一项是默认。
  List<(int, int)> get dayOptions => switch (this) {
        CreditProduct.bank => const [(5, 25)],
        CreditProduct.huabei => const [(1, 9), (5, 15), (10, 20)],
        CreditProduct.fenfu => const [(1, 10)],
        CreditProduct.baitiao => const [(1, 10), (10, 19), (15, 24), (20, 1), (25, 6)],
        CreditProduct.douyin => const [(1, 6), (10, 15), (15, 20)],
      };

  /// 默认条款。数字来自各家公开规则（2026-09 核对）；个人的利率 / 日子以自己 App 的账单页为准，表单里都能改。
  CardTerms defaults({int limitMinor = 0}) {
    final (sd, dd) = dayOptions.first;
    return switch (this) {
      CreditProduct.bank => CardTerms(limitMinor: limitMinor, statementDay: sd, dueDay: dd),
      // 花呗：按时还清免息；逾期 / 只还最低，未还部分从到期次日起按日万分之五计息
      CreditProduct.huabei => CardTerms(limitMinor: limitMinor, statementDay: sd, dueDay: dd, mode: CardInterestMode.afterDue, lateFeeRate: 0, product: this),
      // 分付：每月 1 日出账、还款日可设 5–25 号；按日计息（日利率因人而异，常见约万分之四）；
      // 最低还款 = 已用的 10% + 利息，已用不到 100 元要全还；逾期日利率是正常的 1.5 倍
      CreditProduct.fenfu => CardTerms(limitMinor: limitMinor, statementDay: sd, dueDay: dd, dailyRate: 0.0004, mode: CardInterestMode.daily, lateFeeRate: 0, overdueMultiplier: 1.5, minFullBelowMinor: 10000, product: this),
      // 白条：账单日后 9 天还款；逾期按未还金额每天 0.07% 收违约金
      CreditProduct.baitiao => CardTerms(limitMinor: limitMinor, statementDay: sd, dueDay: dd, dailyRate: 0, mode: CardInterestMode.afterDue, lateFeeRate: 0, lateFeeDailyRate: 0.0007, product: this),
      // 抖音月付：账单日 1 / 10 / 15，对应还款日 6 / 15 / 20；按时还免息，逾期按日计息（以月付页面为准）
      CreditProduct.douyin => CardTerms(limitMinor: limitMinor, statementDay: sd, dueDay: dd, mode: CardInterestMode.afterDue, lateFeeRate: 0, product: this),
    };
  }

  static CreditProduct of(String? name) => CreditProduct.values.asNameMap()[name] ?? CreditProduct.bank;
}

/// 一张信用卡（或花呗 / 分付 / 白条 / 月付）的条款。存在画像里（键 `card:<账户 id>`，随同步走），账本里的账户本身不加字段。
class CardTerms {
  final int limitMinor; // 额度
  final int statementDay; // 账单日（1–28）：这天（含）之前的消费进本期账单
  final int dueDay; // 到期还款日（1–28）：账单日之后第一个这一天
  final double dailyRate; // 日利率：国内信用卡普遍是日万分之五（0.0005，年化约 18.25%）
  final double minPayRatio; // 最低还款比例：普遍 10%
  final double lateFeeRate; // 违约金比例：没还够最低还款时，按「最低还款额 − 已还」的这个比例收（银行信用卡普遍 5%）
  final int lateFeeMinMinor; // 违约金最低收多少（有的行最低 10 元，大多数 0）
  final double lateFeeDailyRate; // 按天收的违约金：逾期后未还金额 × 这个比例 × 天数（白条 0.07%）；0 = 没有
  final double overdueMultiplier; // 逾期后的日利率是正常的几倍（分付 1.5）；1 = 不变
  final int minFullBelowMinor; // 账单低于这个数就得全还（分付 100 元）；0 = 没有这条
  final CardInterestMode mode;
  final CreditProduct product;

  const CardTerms({
    required this.limitMinor,
    required this.statementDay,
    required this.dueDay,
    this.dailyRate = defaultDailyRate,
    this.minPayRatio = defaultMinPayRatio,
    this.lateFeeRate = defaultLateFeeRate,
    this.lateFeeMinMinor = 0,
    this.lateFeeDailyRate = 0,
    this.overdueMultiplier = 1,
    this.minFullBelowMinor = 0,
    this.mode = CardInterestMode.full,
    this.product = CreditProduct.bank,
  });

  static const defaultDailyRate = 0.0005;
  static const defaultMinPayRatio = 0.10;
  static const defaultLateFeeRate = 0.05;

  CardTerms copyWith({int? limitMinor, int? statementDay, int? dueDay, double? dailyRate, double? minPayRatio, double? lateFeeRate, int? lateFeeMinMinor, double? lateFeeDailyRate, double? overdueMultiplier, int? minFullBelowMinor, CardInterestMode? mode, CreditProduct? product}) => CardTerms(
        limitMinor: limitMinor ?? this.limitMinor,
        statementDay: statementDay ?? this.statementDay,
        dueDay: dueDay ?? this.dueDay,
        dailyRate: dailyRate ?? this.dailyRate,
        minPayRatio: minPayRatio ?? this.minPayRatio,
        lateFeeRate: lateFeeRate ?? this.lateFeeRate,
        lateFeeMinMinor: lateFeeMinMinor ?? this.lateFeeMinMinor,
        lateFeeDailyRate: lateFeeDailyRate ?? this.lateFeeDailyRate,
        overdueMultiplier: overdueMultiplier ?? this.overdueMultiplier,
        minFullBelowMinor: minFullBelowMinor ?? this.minFullBelowMinor,
        mode: mode ?? this.mode,
        product: product ?? this.product,
      );

  Map<String, Object?> toJson() => {
        'limit': limitMinor,
        'statement_day': statementDay,
        'due_day': dueDay,
        'daily_rate': dailyRate,
        'min_ratio': minPayRatio,
        'late_fee_rate': lateFeeRate,
        'late_fee_min': lateFeeMinMinor,
        'late_fee_daily': lateFeeDailyRate,
        'overdue_mult': overdueMultiplier,
        'min_full_below': minFullBelowMinor,
        'mode': mode.name,
        'product': product.name,
      };

  /// 解析失败 / 字段缺失返回 null（坏数据不该让整页崩）；数值越界夹回合理范围。0.9.11 存的旧 JSON 没有新字段，按默认补。
  static CardTerms? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int? i(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    double? d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    final limit = i(raw['limit']);
    final sd = i(raw['statement_day']);
    final dd = i(raw['due_day']);
    if (limit == null || sd == null || dd == null) return null;
    return CardTerms(
      limitMinor: limit < 0 ? 0 : limit,
      statementDay: sd.clamp(1, 28),
      dueDay: dd.clamp(1, 28),
      dailyRate: (d(raw['daily_rate']) ?? defaultDailyRate).clamp(0.0, 0.01),
      minPayRatio: (d(raw['min_ratio']) ?? defaultMinPayRatio).clamp(0.0, 1.0),
      lateFeeRate: (d(raw['late_fee_rate']) ?? defaultLateFeeRate).clamp(0.0, 1.0),
      lateFeeMinMinor: (i(raw['late_fee_min']) ?? 0).clamp(0, 1 << 31),
      lateFeeDailyRate: (d(raw['late_fee_daily']) ?? 0).clamp(0.0, 0.01),
      overdueMultiplier: (d(raw['overdue_mult']) ?? 1).clamp(1.0, 5.0),
      minFullBelowMinor: (i(raw['min_full_below']) ?? 0).clamp(0, 1 << 31),
      mode: CardInterestMode.values.asNameMap()[raw['mode']] ?? CardInterestMode.full,
      product: CreditProductX.of(raw['product'] as String?),
    );
  }
}

/// 这一期账单的状态。
enum CardBillState {
  none, // 本期没出账 / 账单是 0
  paid, // 已还清
  due, // 出账了、还没到还款日、还没还清
  overdue, // 过了还款日还没还清
}

/// 一张信用卡此刻的样子：额度用了多少、本期账单、还了多少、最低还款、逾期的违约金和利息。全部从流水推导。
///
/// 「还进去再花出来」：额度按**此刻欠款**算（还一笔额度马上回来，再刷马上占用）；账单按**账单日那天的欠款**算，
/// 账单日之后还的钱算还本期、之后刷的钱进下一期——所以还了 5000 又刷了 3000，本期还剩多少只看那 5000。
class CardStatus {
  final Account account;
  final CardTerms terms;
  final String today;
  final int owedMinor; // 此刻欠款（≥ 0）
  final int overpaidMinor; // 溢缴款（多还进去的，≥ 0）
  final String statementDate; // 最近一次账单日（≤ 今天）
  final String dueDate; // 这期账单的到期还款日
  final String nextStatementDate; // 下一次账单日
  final int statementMinor; // 本期账单金额（账单日那天的欠款）
  final int repaidMinor; // 账单日之后还进去的
  final int repaidByDueMinor; // 其中到期还款日（含）之前还的
  final int newChargesMinor; // 账单日之后新刷的（进下一期）
  final int minPaymentMinor; // 最低还款额
  final int lateFeeMinor; // 违约金：只有过了还款日、还的不够最低还款时才有
  final int interestMinor; // 利息（算到下一个账单日）：只有过了还款日还没还清才有
  final CardBillState state;

  const CardStatus({
    required this.account,
    required this.terms,
    required this.today,
    required this.owedMinor,
    required this.overpaidMinor,
    required this.statementDate,
    required this.dueDate,
    required this.nextStatementDate,
    required this.statementMinor,
    required this.repaidMinor,
    required this.repaidByDueMinor,
    required this.newChargesMinor,
    required this.minPaymentMinor,
    required this.lateFeeMinor,
    required this.interestMinor,
    required this.state,
  });

  /// 本期还剩多少没还。
  int get remainingMinor => statementMinor - repaidMinor > 0 ? statementMinor - repaidMinor : 0;

  /// 最低还款还差多少。
  int get minRemainingMinor => minPaymentMinor - repaidMinor > 0 ? minPaymentMinor - repaidMinor : 0;

  /// 可用额度 = 额度 − 欠款 + 溢缴款；刷超了是 0。
  int get availableMinor {
    final a = terms.limitMinor - owedMinor + overpaidMinor;
    return a > 0 ? a : 0;
  }

  /// 超出额度多少（刷超 / 利息费用把欠款顶过额度）。
  int get overLimitMinor => owedMinor - terms.limitMinor > 0 ? owedMinor - terms.limitMinor : 0;

  /// 额度用了几成（0–1+）；额度是 0 = null。
  double? get usedRatio => terms.limitMinor <= 0 ? null : owedMinor / terms.limitMinor;

  /// 距到期还款日还有几天（负数 = 过了几天）。
  int get daysToDue => CreditCards.daysBetween(today, dueDate);

  /// 过了还款日还没还清：现在要补上的钱 = 还剩的 + 违约金 + 利息（利息算到下个账单日，出现在下期账单上）。
  int get overdueTotalMinor => state == CardBillState.overdue ? remainingMinor + lateFeeMinor + interestMinor : 0;
}

/// 「如果……」的试算：到期只还 [payMinor] 会怎样（利息算到下个账单日）。
class CardProjection {
  final int payMinor;
  final int interestMinor;
  final int lateFeeMinor;
  const CardProjection({required this.payMinor, required this.interestMinor, required this.lateFeeMinor});
  int get costMinor => interestMinor + lateFeeMinor;
}

/// 信用卡：条款读写 + 状态推导。条款存画像（`card:<id>`），状态不落库。
class CreditCards {
  final Ledger ledger;
  CreditCards(this.ledger);

  static const keyPrefix = 'card:';

  CardTerms? terms(String accountId) {
    final raw = ledger.profile.getString('$keyPrefix$accountId');
    if (raw == null) return null;
    try {
      return CardTerms.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  void setTerms(String accountId, CardTerms? t) {
    final a = ledger.getAccount(accountId);
    if (a.type != AccountType.creditCard) throw ArgumentError.value(accountId, 'accountId', 'not a credit card');
    ledger.profile.set('$keyPrefix$accountId', t == null ? null : jsonEncode(t.toJson()));
  }

  /// 新建一张信用卡：账户（期初余额 = −现在欠多少）+ 条款。
  Account add({required String name, required CardTerms terms, int owedMinor = 0, String currency = 'CNY', String? institution}) {
    if (owedMinor < 0) throw ArgumentError.value(owedMinor, 'owedMinor', 'must be >= 0');
    final a = ledger.createAccount(name: name, type: AccountType.creditCard, currency: currency, initialBalanceMinor: -owedMinor, institution: institution, icon: terms.product.emoji);
    setTerms(a.id, terms);
    return a;
  }

  /// 改名字（信用卡 / 花呗这些建好以后也能改）。空名字拒绝。
  Account rename(String accountId, String name) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError.value(name, 'name', 'must not be empty');
    return ledger.updateAccount(accountId, name: n);
  }

  /// 所有设了条款的信用卡此刻的状态（没设条款的不在里面：没账单日算不出账单）。
  List<CardStatus> list({required String today, String? currency}) => [
        for (final a in ledger.listAccounts())
          if (a.type == AccountType.creditCard && (currency == null || a.currency == currency))
            if (status(a.id, today: today) case final s?) s,
      ];

  /// 一张卡此刻的状态；没设条款 = null。
  CardStatus? status(String accountId, {required String today}) {
    final a = ledger.account(accountId);
    if (a == null || a.type != AccountType.creditCard) return null;
    final t = terms(accountId);
    if (t == null) return null;
    final flows = _flows(a);
    final s1 = lastStatementDate(today, t.statementDay);
    final s0 = addMonths(s1, -1);
    final s2 = addMonths(s1, 1);
    final due = dueDateFor(s1, t.dueDay);

    final balanceNow = a.initialBalanceMinor + flows.fold<int>(0, (x, f) => x + f.amount);
    final balanceAtS1 = a.initialBalanceMinor + flows.where((f) => f.date.compareTo(s1) <= 0).fold<int>(0, (x, f) => x + f.amount);
    final stmt = balanceAtS1 < 0 ? -balanceAtS1 : 0;
    var repaid = 0, repaidByDue = 0, newCharges = 0;
    for (final f in flows) {
      if (f.date.compareTo(s1) <= 0 || f.date.compareTo(today) > 0) continue;
      if (f.amount > 0) {
        repaid += f.amount;
        if (f.date.compareTo(due) <= 0) repaidByDue += f.amount;
      } else {
        newCharges += -f.amount;
      }
    }
    final minPay = minPayment(stmt, t);
    final remaining = stmt - repaid > 0 ? stmt - repaid : 0;
    final CardBillState state;
    if (stmt <= 0) {
      state = CardBillState.none;
    } else if (remaining <= 0) {
      state = CardBillState.paid;
    } else if (today.compareTo(due) <= 0) {
      state = CardBillState.due;
    } else {
      state = CardBillState.overdue;
    }
    var fee = 0, interest = 0;
    if (state == CardBillState.overdue) {
      final r = _interest(a, t, flows, s0: s0, s1: s1, due: due, end: s2, statementMinor: stmt, extraPayOnDue: 0, today: today);
      fee = lateFee(minPay, repaidByDue, t) + r.dailyFee;
      interest = r.interest;
    } else if (state == CardBillState.due && t.mode == CardInterestMode.daily) {
      // 按天计息（分付）：按时还清也有利息——显示「到期当天还清」要付的那部分
      interest = _interest(a, t, flows, s0: s0, s1: s1, due: due, end: s2, statementMinor: stmt, extraPayOnDue: remaining, today: today).interest;
    }
    return CardStatus(
      account: a,
      terms: t,
      today: today,
      owedMinor: balanceNow < 0 ? -balanceNow : 0,
      overpaidMinor: balanceNow > 0 ? balanceNow : 0,
      statementDate: s1,
      dueDate: due,
      nextStatementDate: s2,
      statementMinor: stmt,
      repaidMinor: repaid,
      repaidByDueMinor: repaidByDue,
      newChargesMinor: newCharges,
      minPaymentMinor: minPay,
      lateFeeMinor: fee,
      interestMinor: interest,
      state: state,
    );
  }

  /// 试算：这期账单到期一共还 [totalPayMinor]（含已经还了的），利息 / 违约金是多少。还清 = 0。
  /// 用来在还款日之前告诉你「只还最低会多花多少」「一分不还会怎样」。
  CardProjection project(CardStatus s, {required int totalPayMinor}) {
    final pay = totalPayMinor < 0 ? 0 : totalPayMinor;
    if (s.statementMinor <= 0) return CardProjection(payMinor: pay, interestMinor: 0, lateFeeMinor: 0);
    if (pay >= s.statementMinor && s.terms.mode != CardInterestMode.daily) return CardProjection(payMinor: pay, interestMinor: 0, lateFeeMinor: 0);
    final extra = pay - s.repaidByDueMinor > 0 ? pay - s.repaidByDueMinor : 0; // 还没还的那部分假设在还款日当天还上
    final flows = _flows(s.account);
    final r = _interest(s.account, s.terms, flows,
        s0: addMonths(s.statementDate, -1), s1: s.statementDate, due: s.dueDate, end: s.nextStatementDate, statementMinor: s.statementMinor, extraPayOnDue: extra, today: s.dueDate);
    return CardProjection(payMinor: pay, interestMinor: r.interest, lateFeeMinor: lateFee(s.minPaymentMinor, pay, s.terms) + r.dailyFee);
  }

  /// 最低还款额 = 账单 × 比例（向上取整到分）+ 超出额度的部分，不超过账单本身；账单低于「全还线」（分付 100 元）就是全额。
  static int minPayment(int statementMinor, CardTerms t) {
    if (statementMinor <= 0) return 0;
    if (t.minFullBelowMinor > 0 && statementMinor < t.minFullBelowMinor) return statementMinor;
    final over = statementMinor - t.limitMinor > 0 && t.limitMinor > 0 ? statementMinor - t.limitMinor : 0;
    final m = (statementMinor * t.minPayRatio).ceil() + over;
    return m > statementMinor ? statementMinor : m;
  }

  /// 违约金（一次性那部分）：到期还的不够最低还款额，按差额 × 比例收（有最低收费的按最低）；还够了 / 比例是 0 = 0。
  /// 按天收的违约金（白条）在利息那一趟里一起算。
  static int lateFee(int minPayMinor, int paidByDueMinor, CardTerms t) {
    final short = minPayMinor - paidByDueMinor;
    if (short <= 0 || t.lateFeeRate <= 0) return 0;
    final f = (short * t.lateFeeRate).round();
    return f < t.lateFeeMinMinor ? t.lateFeeMinMinor : f;
  }

  /// 按日计息，算到 [end]（下个账单日，利息出现在下期账单上）。还清了就是 0（免息期）。
  ///
  /// 全额计息：这期账单里的每笔本金从它的记账日起每天计息，直到被还掉——还一部分，计息基数就少一部分。
  /// 上期结转过来的欠款按上个账单日次日起算。只对「本期账单」计息，账单日之后的新消费有自己的免息期，不算。
  /// 未还部分计息：到期前按「到期没还的比例」计，到期后按实际没还的计。
  /// 到期后才计息（花呗 / 月付 / 白条）：到期前不计，到期后按实际没还的计。
  /// 按天计息（分付）：不看有没有按时还清，每天按当天还欠着的本金计；逾期后日利率 × [CardTerms.overdueMultiplier]。
  /// 按天收的违约金（白条）：到期后每天按没还的 × [CardTerms.lateFeeDailyRate]，一起算到 [end]。
  ({int interest, int dailyFee}) _interest(Account a, CardTerms t, List<_Flow> flows,
      {required String s0, required String s1, required String due, required String end, required int statementMinor, required int extraPayOnDue, required String today}) {
    if (statementMinor <= 0) return (interest: 0, dailyFee: 0);
    // 本期账单的本金事件：本期消费（+，按日）、上期结转（+，s0 次日）、s0 之后的还款（−，按日）
    final start = addDays(s0, 1);
    final charges = <String, int>{};
    var cycleCharges = 0;
    for (final f in flows) {
      if (f.amount < 0 && f.date.compareTo(s0) > 0 && f.date.compareTo(s1) <= 0) {
        charges[f.date] = (charges[f.date] ?? 0) + -f.amount;
        cycleCharges += -f.amount;
      }
    }
    final payments = <String, int>{};
    var cycleRepaid = 0;
    for (final f in flows) {
      if (f.amount > 0 && f.date.compareTo(s0) > 0 && f.date.compareTo(today) <= 0) {
        payments[f.date] = (payments[f.date] ?? 0) + f.amount;
        if (f.date.compareTo(s1) <= 0) cycleRepaid += f.amount;
      }
    }
    if (extraPayOnDue > 0) payments[due] = (payments[due] ?? 0) + extraPayOnDue;
    // 账单 = 结转 + 本期消费 − 本期内还款；结转 = 账单 − 本期消费 + 本期内还款（期初余额 / 早于 s0 的流水都在这里）
    final carry = statementMinor - cycleCharges + cycleRepaid;
    if (carry > 0) charges[start] = (charges[start] ?? 0) + carry;
    // 到期那天（含）为止还清了：免息
    var paidByDue = 0;
    payments.forEach((d, v) {
      if (d.compareTo(s1) > 0 && d.compareTo(due) <= 0) paidByDue += v;
    });
    if (paidByDue >= statementMinor && t.mode != CardInterestMode.daily) return (interest: 0, dailyFee: 0);
    final unpaidRatio = paidByDue >= statementMinor ? 0.0 : (statementMinor - paidByDue) / statementMinor;

    var balance = 0;
    var interest = 0.0;
    var fee = 0.0;
    for (var d = start; d.compareTo(end) < 0; d = addDays(d, 1)) {
      balance += charges[d] ?? 0;
      balance -= payments[d] ?? 0;
      if (balance < 0) balance = 0;
      final overdue = d.compareTo(due) > 0;
      final double base = switch (t.mode) {
        CardInterestMode.full => balance.toDouble(),
        CardInterestMode.unpaid => overdue ? balance.toDouble() : balance * unpaidRatio,
        CardInterestMode.afterDue => overdue ? balance.toDouble() : 0.0,
        CardInterestMode.daily => balance.toDouble(),
      };
      interest += base * t.dailyRate * (overdue ? t.overdueMultiplier : 1);
      if (overdue) fee += balance * t.lateFeeDailyRate;
    }
    return (interest: interest.round(), dailyFee: fee.round());
  }

  List<_Flow> _flows(Account a) {
    final out = <_Flow>[];
    for (final tx in ledger.listTransactions(accountId: a.id, limit: 1 << 30)) {
      for (final p in tx.postings) {
        if (p.accountId == a.id) out.add(_Flow(tx.occurredAt.localDate, p.amountMinor));
      }
    }
    out.sort((x, y) => x.date.compareTo(y.date));
    return out;
  }

  // ------------------------------------------------------------------ 日期

  /// 最近一次账单日（≤ today）。
  static String lastStatementDate(String today, int statementDay) {
    final p = _parts(today);
    final sd = statementDay.clamp(1, 28);
    return p.$3 >= sd ? _fmt(p.$1, p.$2, sd) : addMonths(_fmt(p.$1, p.$2, sd), -1);
  }

  /// 这期账单的到期还款日：账单日之后第一个 dueDay。
  static String dueDateFor(String statementDate, int dueDay) {
    final p = _parts(statementDate);
    final dd = dueDay.clamp(1, 28);
    return dd > p.$3 ? _fmt(p.$1, p.$2, dd) : addMonths(_fmt(p.$1, p.$2, dd), 1);
  }

  /// 加减月份（日子 ≤ 28，不会溢出）。
  static String addMonths(String date, int months) {
    final p = _parts(date);
    final m0 = p.$1 * 12 + (p.$2 - 1) + months;
    return _fmt(m0 ~/ 12, m0 % 12 + 1, p.$3 > 28 ? 28 : p.$3);
  }

  static String addDays(String date, int days) {
    final p = _parts(date);
    final d = DateTime.utc(p.$1, p.$2, p.$3).add(Duration(days: days));
    return _fmt(d.year, d.month, d.day);
  }

  static int daysBetween(String from, String to) {
    final a = _parts(from), b = _parts(to);
    return DateTime.utc(b.$1, b.$2, b.$3).difference(DateTime.utc(a.$1, a.$2, a.$3)).inDays;
  }

  static (int, int, int) _parts(String s) {
    final p = s.split('-').map(int.parse).toList();
    return (p[0], p[1], p[2]);
  }

  static String _fmt(int y, int m, int d) => '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}

class _Flow {
  final String date;
  final int amount; // 对这张卡：负 = 刷卡 / 费用，正 = 还款 / 退款
  const _Flow(this.date, this.amount);
}
