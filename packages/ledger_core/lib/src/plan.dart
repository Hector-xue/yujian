import 'cards.dart';
import 'debts.dart';
import 'ledger.dart';
import 'wealth.dart';

/// 计划里一笔的种类。
enum PlanItemKind { income, loan, fixed, card }

/// 还款计划里的一笔：哪天、什么、建议付多少、付完手里还剩多少。
class PlanItem {
  final String date;
  final PlanItemKind kind;
  final String name;
  final String? accountId; // 贷款 / 信用卡账户
  final int fullMinor; // 应付全额（收入 = 预计到账）
  final int minMinor; // 最少得付（贷款 / 固定支出 = 全额；信用卡 = 最低还款）
  final int payMinor; // 建议付多少（收入 = 到账额）
  final int balanceAfterMinor; // 这一笔之后手里的钱（可以是负的 = 缺口）
  final bool overdue; // 已经逾期（信用卡）
  const PlanItem({
    required this.date,
    required this.kind,
    required this.name,
    this.accountId,
    required this.fullMinor,
    required this.minMinor,
    required this.payMinor,
    required this.balanceAfterMinor,
    this.overdue = false,
  });

  bool get isIncome => kind == PlanItemKind.income;
  bool get paysOnlyPart => !isIncome && payMinor < fullMinor; // 信用卡没还全额
  bool get short => balanceAfterMinor < 0;
}

/// 还款计划：从今天排到第二个发薪日前一天（覆盖「这个发薪周期」和「下一个」），一笔一笔往下算手里的钱。
class RepaymentPlan {
  final String today;
  final String payday; // 下一个发薪日
  final String until; // 计划排到哪天（含）
  final int startCashMinor; // 起点：手头余额 − 锁进目标的钱
  final int monthlyIncomeMinor; // 每个发薪日按多少到账估（没有收入依据 = 0）
  final List<PlanItem> items;
  const RepaymentPlan({required this.today, required this.payday, required this.until, required this.startCashMinor, required this.monthlyIncomeMinor, required this.items});

  /// 到发薪日（含当天）为止要付的：全额 / 最少。和「可花的」扣的「发薪前要付的」同一个窗口（发薪当天到期的也算），
  /// 两个页面的数才对得上。
  int get dueBeforePaydayFullMinor => _sumBefore((i) => i.fullMinor);
  int get dueBeforePaydayMinMinor => _sumBefore((i) => i.minMinor);

  /// 其中的固定支出 + 月供（不含信用卡）：等于「可花的」里扣的 [WealthMetrics.fixedDueMinor]。
  int get fixedDueBeforePaydayMinor => _sumBefore((i) => i.kind == PlanItemKind.card ? 0 : i.fullMinor);

  int _sumBefore(int Function(PlanItem) f) {
    var s = 0;
    for (final i in items) {
      if (!i.isIncome && i.date.compareTo(payday) <= 0) s += f(i);
    }
    return s;
  }

  /// 最大缺口（手里的钱最低掉到多少，负数取绝对值；没缺口 = 0）。
  int get shortfallMinor {
    var worst = 0;
    for (final i in items) {
      if (i.balanceAfterMinor < worst) worst = i.balanceAfterMinor;
    }
    return -worst;
  }

  /// 只还了一部分的信用卡。
  List<PlanItem> get partialCards => [for (final i in items) if (i.kind == PlanItemKind.card && i.paysOnlyPart) i];
}

/// 生成还款计划。纯推导，不落库。
class RepaymentPlanner {
  final Ledger ledger;
  RepaymentPlanner(this.ledger);

  RepaymentPlan build({required String today, WealthMetrics? metrics, String currency = 'CNY'}) {
    final m = metrics ?? Wealth(ledger).compute(today: today, currency: currency);
    final payday = m.payday;
    // 排到「第二个发薪日」前一天：本周期 + 下一个周期的账单都进来
    final (secondPayday, _) = Wealth(ledger).nextPayday(today: payday);
    final until = CreditCards.addDays(secondPayday, -1);
    final monthlyIncome = m.incomeRank == null ? 0 : m.incomeRank!.annualMinor ~/ 12;

    final raw = <_Event>[];
    // 发薪
    for (var d = payday; d.compareTo(until) <= 0;) {
      if (monthlyIncome > 0) raw.add(_Event(d, PlanItemKind.income, '发薪', null, monthlyIncome, monthlyIncome));
      final (next, _) = Wealth(ledger).nextPayday(today: d);
      if (next.compareTo(d) <= 0) break;
      d = next;
    }
    // 贷款月供 / 固定支出：周期账单在计划区间里的每一期
    final debts = ledger.debts;
    final repay = RepaymentBudget(ledger); // 还贷每期不超过还欠的：分期最后一期只还零头，还清了就没有
    for (final r in ledger.recurring.list()) {
      if (!r.isActive || (r.template['currency'] ?? currency) != currency) continue;
      final isRepay = debts.isRepayment(r);
      final isExpense = r.template['type'] == 'expense';
      if (!isRepay && !isExpense) continue;
      final amount = (r.template['amount_minor'] as num?)?.toInt() ?? 0;
      if (amount <= 0) continue;
      final to = r.template['to_account_id'] as String?;
      if (isRepay && to == null) continue;
      var d = r.nextDue;
      var guard = 0;
      while (d.compareTo(until) <= 0 && guard++ < 400) {
        if (d.compareTo(today) >= 0) {
          final a = isRepay ? repay.take(to!, amount) : amount;
          if (a <= 0) break;
          raw.add(_Event(d, isRepay ? PlanItemKind.loan : PlanItemKind.fixed, r.name, isRepay ? to : null, a, a));
        }
        final n = r.advance(d);
        if (n.compareTo(d) <= 0) break;
        d = n;
      }
    }
    // 收件箱里没确认的周期账单：已经到期、钱还没扣，next_due 却推到下一期了——不补上计划里就漏掉这一笔（「可花的」同样扣它）。
    // 到期日已过的挂今天（今天就该付）
    for (final d in pendingRecurring(ledger, currency: currency, until: until)) {
      final date = d.date.compareTo(today) < 0 ? today : d.date;
      raw.add(_Event(date, d.isRepayment ? PlanItemKind.loan : PlanItemKind.fixed, d.name, d.toAccountId, d.amountMinor, d.amountMinor));
    }
    // 信用卡：本期账单（没还清的；逾期的挂今天）+ 下期账单（账单日后已经刷的，到期日在区间里才算）
    for (final c in ledger.cards.list(today: today, currency: currency)) {
      if (c.state == CardBillState.due || c.state == CardBillState.overdue) {
        final overdue = c.state == CardBillState.overdue;
        final full = overdue ? c.overdueTotalMinor : c.remainingMinor;
        final min = overdue ? full : c.minRemainingMinor;
        raw.add(_Event(overdue ? today : c.dueDate, PlanItemKind.card, c.account.name, c.account.id, full, min, overdue: overdue));
      }
      final nextDue = CreditCards.dueDateFor(c.nextStatementDate, c.terms.dueDay);
      if (c.newChargesMinor > 0 && nextDue.compareTo(until) <= 0) {
        // 下期账单 = 出账后到现在新刷的（之后再刷还会涨，页面上写明）
        final next = c.newChargesMinor;
        raw.add(_Event(nextDue, PlanItemKind.card, '${c.account.name}（下期）', c.account.id, next, CreditCards.minPayment(next, c.terms)));
      }
    }
    // 同一天：先到账，再付必须付的（月供 / 固定支出），最后信用卡
    int order(PlanItemKind k) => switch (k) { PlanItemKind.income => 0, PlanItemKind.loan => 1, PlanItemKind.fixed => 2, PlanItemKind.card => 3 };
    raw.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : order(a.kind).compareTo(order(b.kind));
    });

    // 模拟：信用卡能还全额就全额；不够就在「保住到下次进账前所有必须付的（月供 / 固定 / 各卡最低）」的前提下能还多少还多少
    final start = m.cashMinor - m.lockedMinor;
    var cash = start;
    final items = <PlanItem>[];
    for (var i = 0; i < raw.length; i++) {
      final e = raw[i];
      var pay = e.full;
      if (e.kind == PlanItemKind.income) {
        cash += e.full;
      } else if (e.kind == PlanItemKind.card) {
        var reserve = 0; // 从这一笔之后到下次进账前，必须付的
        for (var j = i + 1; j < raw.length && raw[j].kind != PlanItemKind.income; j++) {
          reserve += raw[j].min;
        }
        final spare = cash - reserve;
        pay = spare >= e.full ? e.full : (spare <= e.min ? e.min : spare);
        cash -= pay;
      } else {
        cash -= pay;
      }
      items.add(PlanItem(date: e.date, kind: e.kind, name: e.name, accountId: e.accountId, fullMinor: e.full, minMinor: e.min, payMinor: pay, balanceAfterMinor: cash, overdue: e.overdue));
    }
    return RepaymentPlan(today: today, payday: payday, until: until, startCashMinor: start, monthlyIncomeMinor: monthlyIncome, items: items);
  }
}

class _Event {
  final String date;
  final PlanItemKind kind;
  final String name;
  final String? accountId;
  final int full;
  final int min;
  final bool overdue;
  const _Event(this.date, this.kind, this.name, this.accountId, this.full, this.min, {this.overdue = false});
}

/// 日历上的一个标记：哪天、什么事、多少钱（不知道 = null）。
enum DueMarkKind { payday, loan, fixed, cardDue, cardStatement }

class DueMark {
  final String date;
  final DueMarkKind kind;
  final String name;
  final int? amountMinor;
  final String? accountId;
  final String note; // 「还剩 / 约 / 已还清」这类补一句
  const DueMark(this.date, this.kind, this.name, {this.amountMinor, this.accountId, this.note = ''});

  bool get isDue => kind == DueMarkKind.loan || kind == DueMarkKind.fixed || kind == DueMarkKind.cardDue;
}

/// 一段日期里（含两头）的还款日 / 账单日 / 发薪日，给日历标注用。只往后推（今天及以后的周期账单；信用卡本期和下期）。
List<DueMark> dueMarks(Ledger ledger, {required String from, required String to, required String today, String currency = 'CNY'}) {
  final out = <DueMark>[];
  bool inRange(String d) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  // 发薪日
  final w = Wealth(ledger);
  var (pd, _) = w.nextPayday(today: CreditCards.addDays(from, -1));
  for (var guard = 0; pd.compareTo(to) <= 0 && guard < 24; guard++) {
    if (inRange(pd) && pd.compareTo(today) >= 0) out.add(DueMark(pd, DueMarkKind.payday, '发薪'));
    final (n, _) = w.nextPayday(today: pd);
    if (n.compareTo(pd) <= 0) break;
    pd = n;
  }
  // 月供 / 固定支出（月供不超过还欠的，还清了就不标）
  final debts = ledger.debts;
  final repay = RepaymentBudget(ledger);
  for (final r in ledger.recurring.list()) {
    if (!r.isActive || (r.template['currency'] ?? currency) != currency) continue;
    final isRepay = debts.isRepayment(r);
    if (!isRepay && r.template['type'] != 'expense') continue;
    final amount = (r.template['amount_minor'] as num?)?.toInt();
    final loan = r.template['to_account_id'] as String?;
    if (isRepay && loan == null) continue;
    var d = r.nextDue;
    for (var guard = 0; d.compareTo(to) <= 0 && guard < 400; guard++) {
      if (d.compareTo(today) >= 0) {
        final a = isRepay ? repay.take(loan!, amount ?? 0) : amount;
        if (isRepay && (a ?? 0) <= 0) break;
        if (inRange(d)) out.add(DueMark(d, isRepay ? DueMarkKind.loan : DueMarkKind.fixed, r.name, amountMinor: a, accountId: isRepay ? loan : null));
      }
      final n = r.advance(d);
      if (n.compareTo(d) <= 0) break;
      d = n;
    }
  }
  // 信用卡类：本期的还款日（还剩多少 / 已还清）、下期（出账后已经刷的，约）、再往后只标日子；账单日也标
  for (final c in ledger.cards.list(today: today, currency: currency)) {
    var s = c.statementDate;
    for (var guard = 0; guard < 24; guard++) {
      final due = CreditCards.dueDateFor(s, c.terms.dueDay);
      if (s.compareTo(to) > 0 && due.compareTo(to) > 0) break;
      if (inRange(s) && s.compareTo(today) > 0) out.add(DueMark(s, DueMarkKind.cardStatement, c.account.name, accountId: c.account.id, note: '出账'));
      if (inRange(due)) {
        if (s == c.statementDate) {
          if (c.statementMinor > 0) {
            out.add(DueMark(due, DueMarkKind.cardDue, c.account.name, amountMinor: c.remainingMinor, accountId: c.account.id, note: c.remainingMinor <= 0 ? '已还清' : (c.state == CardBillState.overdue ? '已逾期' : '还剩')));
          }
        } else if (s == c.nextStatementDate) {
          out.add(DueMark(due, DueMarkKind.cardDue, c.account.name, amountMinor: c.newChargesMinor > 0 ? c.newChargesMinor : null, accountId: c.account.id, note: c.newChargesMinor > 0 ? '约' : '下期'));
        } else {
          out.add(DueMark(due, DueMarkKind.cardDue, c.account.name, accountId: c.account.id, note: '还款日'));
        }
      }
      s = CreditCards.addMonths(s, 1);
    }
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out;
}
