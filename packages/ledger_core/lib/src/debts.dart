import 'goals.dart';
import 'ledger.dart';
import 'models/account.dart';
import 'models/enums.dart';
import 'recurring.dart';

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
  int get paidMinor => (originalMinor - owedMinor).clamp(0, 1 << 62);
  double get paidRatio => originalMinor <= 0 ? 0 : (paidMinor / originalMinor).clamp(0.0, 1.0);
  String? get nextDue => repayment?.nextDue;

  /// 按现在的还款速度还要几个月；没设每月还款 = null。
  int? get monthsLeft => monthlyMinor <= 0 ? null : (owedMinor / monthlyMinor).ceil();
}

/// 全部负债合计。
class DebtTotals {
  final int loanMinor; // 贷款 / 借款（应付类账户）还剩多少
  final int cardMinor; // 信用卡待还
  final int monthlyMinor; // 每月要还的贷款合计（月度化）
  final int count;
  const DebtTotals({required this.loanMinor, required this.cardMinor, required this.monthlyMinor, required this.count});

  int get totalMinor => loanMinor + cardMinor;

  /// 按现在的还款额，贷款还要几个月还清；没设还款 = null。
  int? get monthsLeft => monthlyMinor <= 0 || loanMinor <= 0 ? (loanMinor <= 0 ? 0 : null) : (loanMinor / monthlyMinor).ceil();
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

  DebtTotals totals({String currency = 'CNY'}) {
    var loan = 0;
    var card = 0;
    var monthly = 0;
    var n = 0;
    for (final d in list(currency: currency)) {
      if (d.owedMinor <= 0) continue;
      n++;
      if (d.isCard) {
        card += d.owedMinor;
      } else {
        loan += d.owedMinor;
        monthly += d.monthlyMinor;
      }
    }
    return DebtTotals(loanMinor: loan, cardMinor: card, monthlyMinor: monthly, count: n);
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
