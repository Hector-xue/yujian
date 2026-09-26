import 'cards.dart';
import 'errors.dart';
import 'goals.dart';
import 'ledger.dart';
import 'models/account.dart';
import 'models/enums.dart';
import 'money.dart';
import 'recurring.dart';
import 'wealth.dart';

/// 负债的种类，只决定图标和默认名字；账本里不另存字段，用负债账户的 [Account.icon]（emoji）回推。
enum DebtKind { mortgage, car, online, loan, other }

extension DebtKindX on DebtKind {
  String get label => switch (this) { DebtKind.mortgage => '房贷', DebtKind.car => '车贷', DebtKind.online => '网贷', DebtKind.loan => '借款', DebtKind.other => '其他' };
  String get emoji => switch (this) { DebtKind.mortgage => '🏠', DebtKind.car => '🚗', DebtKind.online => '📱', DebtKind.loan => '🤝', DebtKind.other => '📄' };

  static DebtKind ofIcon(String? icon) {
    for (final k in DebtKind.values) {
      if (k.emoji == icon) return k;
    }
    return DebtKind.other;
  }
}

/// 一笔负债的总览：账户、还剩多少、已还多少、每月还多少、下次几号、还清目标——全部从账本推导。
class DebtSummary {
  final Account account;
  final int owedMinor; // 还剩多少要还（正数；0 = 还清了）
  final int originalMinor; // 建账时的应还总额（期初余额的绝对值）；期初不是负数就等于现在的 owed
  final Recurring? repayment; // 每月还款的周期转账（模板 to_account_id 指向这个账户的、活着的那条）
  final int monthlyMinor; // 月度化的还款额（周供 × 52/12 …）
  final Goal? goal; // 还清目标
  const DebtSummary({required this.account, required this.owedMinor, required this.originalMinor, this.repayment, required this.monthlyMinor, this.goal});

  bool get isCard => account.type == AccountType.creditCard;
  DebtKind get kind => DebtKindX.ofIcon(account.icon);
  int get paidMinor => (originalMinor - owedMinor).clamp(0, maxMinor);
  double get paidRatio => originalMinor <= 0 ? 0 : (paidMinor / originalMinor).clamp(0.0, 1.0);
  String? get nextDue => repayment?.nextDue;

  /// 按现在的还款速度还要几个月；没设每月还款 = null。
  int? get monthsLeft => monthlyMinor <= 0 ? null : (owedMinor / monthlyMinor).ceil();
}

/// 全部负债合计。
///
/// 两种「每月还」要分清：
/// - [loanMonthlyMinor] 贷款月供（周期转账月度化）：每月固定流出，等级 / 可花的 / 月供占收入按这个扣；
/// - [cardDueMinor] 各张信用卡**最近一期**要还的：信用卡刷的时候已经记成支出了，只在「这个月要还多少」里出现，
///   不能再算进月支出（否则同一笔消费扣两次）。
/// [monthlyMinor] = 两者相加，是负债页「每月还款」给人看的数。
class DebtTotals {
  final int loanMinor; // 贷款 / 借款（应付类账户）还剩多少
  final int cardMinor; // 信用卡此刻欠多少
  final int loanMonthlyMinor; // 每月要还的贷款合计（月度化）
  final int cardDueMinor; // 各张卡最近一期要还的合计（见 [Debts.cardDue]）
  final int cardsWithoutTerms; // 没设账单日的卡：算不出账单，按全部欠款算进了 [cardDueMinor]
  final int loansWithoutRepayment; // 还欠着、却没设每月还款的贷款笔数
  final int loanMaxMonthsLeft; // 设了还款的贷款里，最晚还清的那笔还要几个月（没有 = 0）
  final int count;
  const DebtTotals({
    required this.loanMinor,
    required this.cardMinor,
    required this.loanMonthlyMinor,
    this.cardDueMinor = 0,
    this.cardsWithoutTerms = 0,
    this.loansWithoutRepayment = 0,
    this.loanMaxMonthsLeft = 0,
    required this.count,
  });

  int get totalMinor => loanMinor + cardMinor;

  /// 这个月要还的：贷款月供 + 各张卡最近一期账单。
  int get monthlyMinor => loanMonthlyMinor + cardDueMinor;

  /// 贷款全部还清还要几个月：每笔各还各的，取最晚的那笔（不能拿总余额 ÷ 总月供——小额的先还完，
  /// 剩下那笔的月供不会挪过去）。没有贷款 = 0；有一笔欠着却没设还款 = null（永远还不清，说不出月数）。
  int? get monthsLeft => loanMinor <= 0 ? 0 : (loansWithoutRepayment > 0 ? null : loanMaxMonthsLeft);
}

/// 还贷每期实际要还多少：不超过这个贷款账户还欠的（扣掉收件箱里已经起草、还没确认的还款），逐期往下扣；还清了 = 0。
/// 周期项起草、「可花的」、还款计划、日历都用它——分期最后一期只还零头，还清了就不再扣，不会多还。
class RepaymentBudget {
  final Ledger ledger;
  final Map<String, int> _left = {};
  RepaymentBudget(this.ledger);

  /// 这个贷款账户还能还多少。
  int left(String accountId) => _left.putIfAbsent(accountId, () {
        final a = ledger.account(accountId);
        if (a == null) return 0;
        final b = ledger.balance(accountId).minor;
        var owed = b < 0 ? -b : 0;
        for (final d in pendingRecurring(ledger, currency: a.currency)) {
          if (d.isRepayment && d.toAccountId == accountId) owed -= d.amountMinor;
        }
        return owed > 0 ? owed : 0;
      });

  /// 这一期要还 [amountMinor]：返回实际还多少（不超过剩下的），并从剩下的里扣掉。
  int take(String accountId, int amountMinor) {
    final l = left(accountId);
    final a = amountMinor < l ? amountMinor : l;
    final paid = a > 0 ? a : 0;
    _left[accountId] = l - paid;
    return paid;
  }
}

/// 删一笔负债的结果：账户是真删了（没有还款记录）还是退成归档（有记录，历史不能丢）。
class DebtRemoval {
  final bool accountDeleted;
  final int postingCount; // 这个账户上的交易记录数；> 0 时账户只归档
  final int repaymentsRemoved;
  final int goalsRemoved;
  const DebtRemoval({required this.accountDeleted, required this.postingCount, required this.repaymentsRemoved, required this.goalsRemoved});
}

/// 建好的三件：负债账户、每月还款的周期转账（没填每月还款就没有）、还清目标。
class DebtSetup {
  final Account account;
  final Recurring? repayment;
  final Goal goal;
  const DebtSetup({required this.account, required this.repayment, required this.goal});
}

/// 负债：一张表单建三件（账户 + 周期转账 + 还清目标），总览全部由账本推导。
///
/// 口径：**负债账户的余额 = 还剩多少要还（本息合计），每月还款 = 一笔转账到这个账户。**
/// 这样净资产自动为负、随还款上升；还清目标跟账户余额走；可花的 / 等级按「发薪前要还的」「每月要还的」扣。
/// 不拆本金利息（普通人记不住，也不需要）。
class Debts {
  final Ledger ledger;
  Debts(this.ledger);

  static bool isLiability(AccountType t) => t == AccountType.creditCard || t == AccountType.payable;

  /// 周期模板是不是「还贷」：转账、转入方是应付类账户。
  bool isRepayment(Recurring r) {
    if (r.template['type'] != 'transfer') return false;
    final to = r.template['to_account_id'] as String?;
    if (to == null) return false;
    final a = ledger.account(to);
    return a != null && a.type == AccountType.payable;
  }

  /// 把任意周期折成每月多少。
  static int monthly(Recurring r) {
    final amount = ((r.template['amount_minor'] as num?)?.toInt() ?? 0);
    final n = r.interval < 1 ? 1 : r.interval;
    return switch (r.frequency) {
      Frequency.daily => amount * 30 ~/ n,
      Frequency.weekly => (amount * 52 / 12 / n).round(),
      Frequency.monthly => amount ~/ n,
      Frequency.yearly => amount ~/ (12 * n),
    };
  }

  /// 一张表单建三件。[owedMinor] 是还剩多少要还，[monthlyMinor] 每月还多少（0 = 先不设），[day] 每月几号（1–28），
  /// [fromAccountId] 从哪个账户扣。
  DebtSetup add({
    required String name,
    required DebtKind kind,
    required int owedMinor,
    int monthlyMinor = 0,
    int day = 1,
    String? fromAccountId,
    String currency = 'CNY',
    required String today,
  }) {
    if (owedMinor <= 0) throw ArgumentError.value(owedMinor, 'owedMinor', 'must be > 0');
    if (monthlyMinor < 0) throw ArgumentError.value(monthlyMinor, 'monthlyMinor', 'must be >= 0');
    if (monthlyMinor > 0 && fromAccountId == null) throw ArgumentError.notNull('fromAccountId');
    final d = day.clamp(1, 28);
    final account = ledger.createAccount(name: name, type: AccountType.payable, currency: currency, initialBalanceMinor: -owedMinor, icon: kind.emoji);
    Recurring? repayment;
    if (monthlyMinor > 0) {
      repayment = ledger.recurring.create(
        name: '$name 还款',
        template: {'type': 'transfer', 'amount_minor': monthlyMinor, 'currency': currency, 'account_id': fromAccountId, 'to_account_id': account.id, 'description': '$name 还款'},
        frequency: Frequency.monthly,
        firstDue: _nextDay(today, d),
        reminderDaysBefore: 3,
      );
    }
    final goal = ledger.goals.create(kind: GoalKind.payoff, name: '还清$name', targetMinor: owedMinor, emoji: kind.emoji, currency: currency, linkedAccountId: account.id, withVault: false);
    return DebtSetup(account: account, repayment: repayment, goal: goal);
  }

  /// 已有的负债账户补一条每月还款（换了金额就停掉旧的那条）。
  Recurring setRepayment(String accountId, {required int monthlyMinor, required int day, required String fromAccountId, required String today}) {
    final a = ledger.getAccount(accountId);
    for (final r in ledger.recurring.list()) {
      if (r.template['to_account_id'] == accountId && isRepayment(r)) ledger.recurring.setActive(r.id, false);
    }
    return ledger.recurring.create(
      name: '${a.name} 还款',
      template: {'type': 'transfer', 'amount_minor': monthlyMinor, 'currency': a.currency, 'account_id': fromAccountId, 'to_account_id': accountId, 'description': '${a.name} 还款'},
      frequency: Frequency.monthly,
      firstDue: _nextDay(today, day.clamp(1, 28)),
      reminderDaysBefore: 3,
    );
  }

  /// 删一笔负债：还款的周期转账（活着的、停掉的都算）和还清目标一起删；账户没有任何交易记录就真删，
  /// 有还款记录就归档（历史交易还指着它，删了对不上），账户页「已归档」里能恢复。
  DebtRemoval remove(String accountId) {
    final a = ledger.getAccount(accountId);
    if (!isLiability(a.type)) throw InvalidStateException('not a liability account');
    return ledger.database.transaction(() {
      var reps = 0;
      for (final r in ledger.recurring.list(activeOnly: false)) {
        if (r.template['to_account_id'] == accountId && r.template['type'] == 'transfer') {
          ledger.recurring.delete(r.id);
          reps++;
        }
      }
      var goals = 0;
      for (final g in ledger.goals.list(activeOnly: false)) {
        if (g.kind == GoalKind.payoff && g.linkedAccountId == accountId) {
          ledger.goals.delete(g.id);
          goals++;
        }
      }
      final n = ledger.accountPostingCount(accountId);
      if (n > 0) {
        if (!a.isArchived) ledger.archiveAccount(accountId);
      } else {
        ledger.deleteAccount(accountId);
      }
      return DebtRemoval(accountDeleted: n == 0, postingCount: n, repaymentsRemoved: reps, goalsRemoved: goals);
    });
  }

  /// 全部负债账户（信用卡 + 应付），按还剩多少倒序；还清了的排最后。
  List<DebtSummary> list({String? currency}) {
    final recurring = ledger.recurring.list();
    final goals = ledger.goals.list();
    final out = <DebtSummary>[];
    for (final a in ledger.listAccounts()) {
      if (!isLiability(a.type)) continue;
      if (currency != null && a.currency != currency) continue;
      final b = ledger.balance(a.id).minor;
      final owed = b < 0 ? -b : 0;
      final original = a.initialBalanceMinor < 0 ? -a.initialBalanceMinor : owed;
      Recurring? rep;
      for (final r in recurring) {
        if (r.template['to_account_id'] == a.id && r.template['type'] == 'transfer') {
          rep = r;
          break;
        }
      }
      Goal? goal;
      for (final g in goals) {
        if (g.kind == GoalKind.payoff && g.linkedAccountId == a.id) {
          goal = g;
          break;
        }
      }
      out.add(DebtSummary(account: a, owedMinor: owed, originalMinor: original < owed ? owed : original, repayment: rep, monthlyMinor: rep == null ? 0 : monthly(rep), goal: goal));
    }
    out.sort((x, y) => y.owedMinor.compareTo(x.owedMinor));
    return out;
  }

  /// 全部负债合计。[today] 用来算信用卡的本期 / 下期账单。
  DebtTotals totals({required String today, String currency = 'CNY'}) {
    var loan = 0, card = 0, monthly = 0, due = 0, bare = 0, noRepay = 0, maxLeft = 0, n = 0;
    for (final d in list(currency: currency)) {
      if (d.owedMinor <= 0) continue;
      n++;
      if (d.isCard) {
        card += d.owedMinor;
        final s = ledger.cards.status(d.account.id, today: today);
        if (s == null) bare++;
        due += cardDue(d.owedMinor, s);
      } else {
        loan += d.owedMinor;
        monthly += d.monthlyMinor;
        final left = d.monthsLeft;
        if (left == null) {
          noRepay++;
        } else if (left > maxLeft) {
          maxLeft = left;
        }
      }
    }
    return DebtTotals(
      loanMinor: loan,
      cardMinor: card,
      loanMonthlyMinor: monthly,
      cardDueMinor: due,
      cardsWithoutTerms: bare,
      loansWithoutRepayment: noRepay,
      loanMaxMonthsLeft: maxLeft,
      count: n,
    );
  }

  /// 一张卡最近一期要还多少：
  /// - 本期出账了、还没还清 → 本期还剩的（逾期了连违约金和利息）；
  /// - 本期还清了 / 没出账 → 下一期：出账后到现在新刷的（之后再刷还会涨），不超过此刻欠款；
  /// - 没设账单日（[s] = null）→ 算不出账单，按此刻全部欠款算（宁多勿少，页面上写明）。
  static int cardDue(int owedMinor, CardStatus? s) {
    if (s == null) return owedMinor;
    return switch (s.state) {
      CardBillState.overdue => s.overdueTotalMinor,
      CardBillState.due => s.remainingMinor,
      CardBillState.paid || CardBillState.none => s.newChargesMinor < owedMinor ? s.newChargesMinor : owedMinor,
    };
  }

  /// 从 [today] 起（含今天）下一个「每月 day 号」。
  static String _nextDay(String today, int day) {
    final p = today.split('-').map(int.parse).toList();
    var y = p[0];
    var m = p[1];
    if (p[2] > day) {
      m += 1;
      if (m > 12) {
        m = 1;
        y += 1;
      }
    }
    return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  }
}
