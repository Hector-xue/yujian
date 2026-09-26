import 'cards.dart';
import 'debts.dart';
import 'goals.dart';
import 'ledger.dart';
import 'money.dart';
import 'plan.dart';
import 'wealth.dart';

/// 一条发现的好坏。
enum CheckTone { good, ok, warn, bad }

/// 体检里的一条发现：标题 + 依据（带数字）。
class CheckFinding {
  final CheckTone tone;
  final String title;
  final String detail;
  const CheckFinding(this.tone, this.title, this.detail);
}

/// 调优方案里的一步（按先后排好）。
class CheckStep {
  final String title;
  final String detail;
  final int? amountMinor; // 这一步涉及的钱（没有 = null）
  const CheckStep(this.title, this.detail, {this.amountMinor});
}

/// 资金规整：不缺钱时，手里的钱分成三份各干各的。
class MoneyBuckets {
  final int emergencyMinor; // 应急金：留在随时能取的地方
  final int nearTermMinor; // 一年内要用的（有截止日的目标还差的）
  final int longTermMinor; // 剩下的长期闲钱
  const MoneyBuckets({required this.emergencyMinor, required this.nearTermMinor, required this.longTermMinor});
}

/// 资产体检：给每个人一张清楚的资产状况 + 一份按先后排好的调优方案。全部从账本推导，规则写死在这里（可测、可解释），不调模型。
class Checkup {
  final WealthMetrics m;
  final int monthlyIncomeMinor; // 月收入（按收入排位那套年化 ÷ 12）
  final int highInterestMinor; // 高息负债：逾期 / 循环中的信用卡类 + 网贷
  final double? cardUsage; // 所有信用卡类合计：欠款 ÷ 额度
  final double? repayRatio; // 每月还贷 ÷ 月收入
  final int emergencyTargetMinor; // 应急金目标（有负债 3 个月、没有 6 个月）
  final List<CheckFinding> findings;
  final List<CheckStep> steps;
  final MoneyBuckets? buckets; // 只在不缺钱（没高息负债、应急金够）时有
  const Checkup({
    required this.m,
    required this.monthlyIncomeMinor,
    required this.highInterestMinor,
    required this.cardUsage,
    required this.repayRatio,
    required this.emergencyTargetMinor,
    required this.findings,
    required this.steps,
    required this.buckets,
  });

  bool get hasBad => findings.any((f) => f.tone == CheckTone.bad);
}

class Checkups {
  final Ledger ledger;
  Checkups(this.ledger);

  static String _y(int minor) => '¥${Money(minor, 'CNY').toDecimalString()}';

  Checkup run({required String today, WealthMetrics? metrics, RepaymentPlan? plan}) {
    final m = metrics ?? Wealth(ledger).compute(today: today);
    final p = plan ?? RepaymentPlanner(ledger).build(today: today, metrics: m);
    final cards = ledger.cards.list(today: today, currency: m.currency);
    final debts = ledger.debts.list(currency: m.currency);
    final monthlyIncome = m.incomeRank == null ? m.monthIncomeMinor : m.incomeRank!.annualMinor ~/ 12;
    final baseline = m.monthlySpendAvgMinor;

    // 高息负债：逾期的 / 本期没打算还清的信用卡类（会开始计息），以及网贷
    var highInterest = 0;
    final overdue = <CardStatus>[];
    var cardOwed = 0, cardLimit = 0;
    for (final c in cards) {
      cardOwed += c.owedMinor;
      cardLimit += c.terms.limitMinor;
      if (c.state == CardBillState.overdue) {
        overdue.add(c);
        highInterest += c.overdueTotalMinor;
      }
    }
    for (final pc in p.partialCards) {
      highInterest += pc.fullMinor - pc.payMinor;
    }
    for (final d in debts) {
      if (!d.isCard && d.kind == DebtKind.online) highInterest += d.owedMinor;
    }
    final cardUsage = cardLimit > 0 ? cardOwed / cardLimit : null;
    final repayRatio = monthlyIncome > 0 && m.debt.loanMonthlyMinor > 0 ? m.debt.loanMonthlyMinor / monthlyIncome : null; // 月供只算贷款：信用卡账单是已经记过的支出，另看额度那条
    final hasDebt = m.debt.totalMinor > 0;
    final targetMonths = hasDebt ? 3 : 6;
    final emergencyTarget = baseline > 0 ? baseline * targetMonths : 0;
    final runway = m.runwayMonths;

    final f = <CheckFinding>[];
    final steps = <CheckStep>[];

    // 1. 逾期：最要紧
    if (overdue.isNotEmpty) {
      final total = overdue.fold<int>(0, (a, c) => a + c.overdueTotalMinor);
      f.add(CheckFinding(CheckTone.bad, '有 ${overdue.length} 笔逾期', '${overdue.map((c) => c.account.name).join('、')} 过了还款日，连违约金和利息约 ${_y(total)}；拖得越久越贵，还会上征信。'));
      steps.add(CheckStep('先把逾期的还上', '哪怕先还到最低还款也行，先止住违约金和征信记录。', amountMinor: total));
    }
    // 2. 发薪前的缺口
    if (p.shortfallMinor > 0) {
      f.add(CheckFinding(CheckTone.bad, '发薪前差 ${_y(p.shortfallMinor)}', '按还款计划，手头的钱不够付完这期的月供和各卡最低还款。'));
      steps.add(CheckStep('补上发薪前的缺口', '先保月供和各卡最低还款（不上征信）；能缓的支出往后放。别用新的网贷去填旧的——利息只会越滚越多。', amountMinor: p.shortfallMinor));
    }
    // 3. 应急金
    if (baseline > 0 && runway != null) {
      final tone = runway < 1 ? CheckTone.bad : (runway < 3 ? CheckTone.warn : (runway < 6 ? CheckTone.ok : CheckTone.good));
      f.add(CheckFinding(tone, '手头的钱够花 ${runway.toStringAsFixed(1)} 个月', '按每月 ${_y(baseline)} 算。${hasDebt ? '有负债时' : ''}应急金建议至少 $targetMonths 个月（${_y(emergencyTarget)}）。'));
    }
    // 4. 还款压力
    if (repayRatio != null) {
      final tone = repayRatio > 0.5 ? CheckTone.bad : (repayRatio > 0.3 ? CheckTone.warn : CheckTone.ok);
      f.add(CheckFinding(tone, '月供占收入 ${(repayRatio * 100).toStringAsFixed(0)}%', '每月还贷 ${_y(m.debt.loanMonthlyMinor)} / 月收入 ${_y(monthlyIncome)}。超过一半很吃紧，三成以内比较稳。'));
    }
    // 5. 信用卡额度
    if (cardUsage != null) {
      final tone = cardUsage > 0.9 ? CheckTone.bad : (cardUsage > 0.7 ? CheckTone.warn : CheckTone.ok);
      f.add(CheckFinding(tone, '信用额度用了 ${(cardUsage * 100).toStringAsFixed(0)}%', '欠 ${_y(cardOwed)} / 总额度 ${_y(cardLimit)}（信用卡、花呗、白条这些合计）。长期用到七成以上，征信上看着紧张。'));
    }
    // 6. 储蓄率
    if (m.savingsRate != null) {
      final r = m.savingsRate!;
      final tone = r < 0 ? CheckTone.bad : (r < 0.1 ? CheckTone.warn : (r < 0.3 ? CheckTone.ok : CheckTone.good));
      f.add(CheckFinding(tone, r < 0 ? '这个月花得比挣得多' : '这个月存下 ${(r * 100).toStringAsFixed(0)}%', '本月收入 ${_y(m.monthIncomeMinor)}，支出 ${_y(m.monthExpenseMinor)}。'));
    }
    // 7. 高息负债
    if (highInterest > 0) {
      f.add(CheckFinding(CheckTone.warn, '高息负债 ${_y(highInterest)}', '没还清的信用卡 / 花呗这类和网贷，年化常见 14%–18% 甚至更高，比几乎任何理财收益都高。'));
      steps.add(CheckStep('高息的先还', '多出来的钱先还利率最高的那笔（信用卡循环、网贷），还掉一块钱就等于稳赚那一块钱的利息。房贷这类低息的按期还就好。', amountMinor: highInterest));
    }
    // 8. 应急金没攒够 → 攒
    if (emergencyTarget > 0 && m.liquidMinor < emergencyTarget) {
      steps.add(CheckStep('把应急金攒到 $targetMonths 个月', '还差 ${_y(emergencyTarget - m.liquidMinor)}。可以建一个「应急金」目标，每次发薪先锁一部分。', amountMinor: emergencyTarget - m.liquidMinor));
    }

    // 9. 不缺钱：资金规整
    MoneyBuckets? buckets;
    if (highInterest <= 0 && p.shortfallMinor <= 0 && emergencyTarget > 0 && m.liquidMinor >= emergencyTarget) {
      var nearTerm = 0;
      final oneYear = CreditCards.addMonths(today, 12);
      for (final g in ledger.goals.list()) {
        if (g.kind == GoalKind.payoff || g.currency != m.currency) continue;
        if (g.deadline != null && g.deadline!.compareTo(oneYear) <= 0) {
          final left = g.targetMinor - ledger.goals.savedMinor(g);
          if (left > 0) nearTerm += left;
        }
      }
      final free = m.liquidMinor - emergencyTarget;
      final near = nearTerm < free ? nearTerm : free;
      final long = free - near;
      buckets = MoneyBuckets(emergencyMinor: emergencyTarget, nearTermMinor: near, longTermMinor: long);
      steps.add(CheckStep('应急金 ${_y(emergencyTarget)} 留在随时能取的地方', '$targetMonths 个月的生活费，活期 / 货币基金这类随用随取的。它的任务是兜底，不是赚钱。', amountMinor: emergencyTarget));
      if (near > 0) steps.add(CheckStep('一年内要用的 ${_y(near)} 单独放', '给一年内到期的目标备着，锁进对应目标里，别拿去冒风险。', amountMinor: near));
      if (long > 0) {
        steps.add(CheckStep('长期闲钱 ${_y(long)} 让它干活', '三年以上用不到的钱，可以考虑定期存款、国债、稳健的基金这类低风险去处，或者给长期目标（买房首付、养老）锁仓。分散放、别追高。余见不卖理财，也不推荐具体产品。', amountMinor: long));
      }
      f.add(const CheckFinding(CheckTone.good, '没有高息负债、应急金够了', '底子是稳的——接下来是让钱各司其职。'));
    }
    if (steps.isEmpty) steps.add(const CheckStep('保持现在的节奏', '记账记下去，每月看一眼这里；等有了几个月的数据，建议会更准。'));
    const order = {CheckTone.bad: 0, CheckTone.warn: 1, CheckTone.ok: 2, CheckTone.good: 3};
    f.sort((a, b) => order[a.tone]!.compareTo(order[b.tone]!));
    return Checkup(
      m: m,
      monthlyIncomeMinor: monthlyIncome,
      highInterestMinor: highInterest,
      cardUsage: cardUsage,
      repayRatio: repayRatio,
      emergencyTargetMinor: emergencyTarget,
      findings: f,
      steps: steps,
      buckets: buckets,
    );
  }
}
