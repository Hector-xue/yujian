import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../game/cheer.dart';
import '../theme.dart';
import '../widgets/cheer_carousel.dart';
import '../widgets/credit_card_sheet.dart';
import '../widgets/fmt.dart';
import 'automation_page.dart';
import 'budgets_page.dart';
import 'goals_page.dart';
import 'tasks_page.dart';
import 'transactions_page.dart';
import 'wealth_page.dart';

/// 首页列表的左右页边距；目标横滑条要把它吃回来（视口铺满屏宽）再自己留出来，所以单独记一份。
const _gutter = 20.0;

/// 首页：本月支出/收入、账户合计、最近几笔。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final now = DateTime.now();
    final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    final last = DateTime(now.year, now.month + 1, 0).day;
    final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${last.toString().padLeft(2, '0')}';
    final expense = app.engine.run(QueryDsl(timeRange: DateRange(from, to)));
    final income = app.engine.run(QueryDsl(types: const [TransactionType.income], timeRange: DateRange(from, to)));
    final recent = app.ledger.listTransactions(limit: 5);
    final alerts = app.budgetAlerts();
    final anomalies = app.homeAnomalies().take(3).toList();
    final upcoming = app.ledger.recurring.upcoming(today: todayLocal());
    // 信用卡：7 天内到期还没还清的、已经逾期的，和周期账单放一起提醒
    final cardsDue = [for (final c in app.cardStatuses()) if (c.state == CardBillState.overdue || (c.state == CardBillState.due && c.daysToDue <= 7)) c];
    int sumCny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
    // 余额 = 手头的钱（现金 / 银行卡 / 钱包 / 锁仓，负的也减）：锁进目标的钱也在手机里，「可花的」才扣它。
    // 信用卡 / 贷款 / 投资不在这里（它们在净资产里，财富页看）——以前全加在一起，「可花的」就可能比「余额」还多
    final totalBalance = Wealth.cashOnHand(app.ledger);

    return Scaffold(
      appBar: AppBar(title: Text('${now.month} 月')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(_gutter, 4, _gutter, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          // 财富游戏层开着：第一眼看「可花的」（余额降为第二行）；关着：老样子。两种都在同一个 builder 里，重算后不会双份
          ListenableBuilder(
            listenable: app.game,
            builder: (context, _) => app.game.enabled && app.game.metrics != null
                ? _GameHeader(expense: sumCny(expense.rows), income: sumCny(income.rows))
                : _BalanceCard(totalBalance: totalBalance, expense: sumCny(expense.rows), income: sumCny(income.rows)),
          ),
          ListenableBuilder(listenable: app.game, builder: (context, _) => app.game.enabled ? const _GoalsStrip() : const SizedBox.shrink()),
          if (app.showAutoHint) ...[
            const SizedBox(height: 14),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(children: [
                  Icon(Icons.bolt_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('自动记账还没开', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text('微信、支付宝、淘宝、京东、美团付完款自动记上，不用再手动输', style: theme.textTheme.bodySmall),
                    ]),
                  ),
                  TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AutomationPage())), child: const Text('去开启')),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: app.dismissAutoHint, tooltip: '不再提示'),
                ]),
              ),
            ),
          ],
          // 太久没打开、没自动补的周期账单：说清楚是哪几期，要补就手记
          if (app.recurringSkipped.isNotEmpty) ...[
            const SizedBox(height: 14),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.event_busy_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('这几期太久没打开，没有自动补', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text('${app.recurringSkipped.join('\n')}\n真付过的话手动补记一下。', style: theme.textTheme.bodySmall),
                    ]),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: app.dismissRecurringSkipped, tooltip: '知道了'),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 24),
          // 下面几块和「最近」一样都是卡片：裸行夹在卡片中间看着不像一套
          if (alerts.isNotEmpty) ...[
            Text('预算', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(children: [for (final a in alerts) BudgetBar(status: a)]),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (anomalies.isNotEmpty) ...[
            Row(children: [
              Text('比平时高', style: theme.textTheme.bodySmall),
              const Spacer(),
              Text('最近 ${AppState.homeAnomalyDays} 天 · 左滑不再提', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
            ]),
            const SizedBox(height: 4),
            GlassCard(
              child: Column(children: [
                for (final a in anomalies)
                  Dismissible(
                    key: ValueKey('anomaly-${a.tx.id}'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) => app.dismissAnomaly(a.tx.id),
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      color: y.muted.withValues(alpha: 0.15),
                      child: Icon(Icons.visibility_off_outlined, color: y.muted),
                    ),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      title: Text(a.tx.description ?? app.categoryName(a.tx.categoryId), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${a.tx.occurredAt.localDate.substring(5).replaceFirst('-', '/')} · 是平时的 ${a.ratio.toStringAsFixed(1)} 倍', style: theme.textTheme.bodySmall),
                      trailing: Text(fmtMoney(a.tx.amountMinor, a.tx.currency), style: theme.textTheme.titleMedium?.copyWith(color: y.expense, fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (upcoming.isNotEmpty || cardsDue.isNotEmpty) ...[
            Text('近期到期', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            GlassCard(
              child: Column(children: [
                for (final c in cardsDue)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    onTap: () => showCreditCardSheet(context, c.account),
                    title: Text('💳 ${c.account.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(cardBillLine(c), style: theme.textTheme.bodySmall?.copyWith(color: c.state == CardBillState.overdue ? y.danger : null), maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(fmtMoney(c.state == CardBillState.overdue ? c.overdueTotalMinor : c.remainingMinor, 'CNY'), style: theme.textTheme.titleMedium?.copyWith(color: c.state == CardBillState.overdue ? y.danger : null, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                for (final r in upcoming)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(r.nextDue.substring(5).replaceFirst('-', '/'), style: theme.textTheme.bodySmall),
                    trailing: Text(fmtMoney(r.template['amount_minor'] as int, r.template['currency'] as String), style: theme.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (recent.isNotEmpty) ...[
            Text('最近', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            GlassCard(
              child: Column(children: [for (final t in recent) TransactionTile(tx: t)]),
            ),
          ],
        ],
      ),
    );
  }
}

/// 老样子的余额卡（游戏层关着时）。
class _BalanceCard extends StatelessWidget {
  final int totalBalance;
  final int expense;
  final int income;
  const _BalanceCard({required this.totalBalance, required this.expense, required this.income});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.account_balance_wallet_outlined, size: 16, color: y.balance),
                    const SizedBox(width: 6),
                    Text('现金余额', style: theme.textTheme.bodySmall?.copyWith(color: y.balance, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 4),
                  _BigMoney(fmtMoney(totalBalance, 'CNY'), color: y.balance),
                  const SizedBox(height: 14),
                  _StatRow(
                    children: [
                      _Stat(label: '本月支出', value: fmtMoney(expense, 'CNY'), color: y.expense),
                      _Stat(label: '本月收入', value: fmtMoney(income, 'CNY'), color: y.income),
                      _Stat(
                          label: '结余',
                          value: fmtMoney(income - expense, 'CNY'),
                          color: (income - expense) < 0 ? y.danger : theme.colorScheme.onSurface),
                    ],
                  ),
                ],
              ),
            ),
          );
  }
}

/// 可花的 / 今天还能花 / 等级：游戏层的首页头卡。
class _GameHeader extends StatelessWidget {
  final int expense;
  final int income;
  const _GameHeader({required this.expense, required this.income});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final m = app.game.metrics!;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return GlassCard(
      child: InkWell(
        onTap: () => go(const WealthPage()),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.account_balance_wallet_outlined, size: 16, color: y.balance),
              const SizedBox(width: 6),
              Text('可花的', style: theme.textTheme.bodySmall?.copyWith(color: y.balance, fontWeight: FontWeight.w600)),
              // 角标靠右、能用整段剩余宽度，窄屏只会省略号不会溢出
              Expanded(child: Align(alignment: Alignment.centerRight, child: m.title == null ? const SizedBox.shrink() : _TitleBadge(m: m))),
            ]),
            const SizedBox(height: 4),
            _BigMoney(fmtMoney(m.disposableMinor, 'CNY'), color: m.disposableMinor < 0 ? y.danger : y.balance),
            // 只留一行：今天还能花多少、几天后发薪。公式在财富页（点卡片进），首页不摆三行小字
            Text(
              m.disposableMinor < 0 ? '发薪前得省着：固定支出比手头的钱多 · ${m.daysToPayday} 天后发薪' : '今天还能花 ${fmtMoney(m.dailyAllowanceMinor, 'CNY')} · ${m.daysToPayday} 天后发薪',
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            // 现金余额 = 现金 / 银行卡 / 钱包 / 锁仓相加（和「可花的」同一次计算，可花的 ≤ 它）；总资产 = 非负债账户相加（含投资，透支的照减，不扣负债）
            _StatRow(children: [
              _Stat(label: '现金余额', value: fmtMoney(m.cashMinor, 'CNY')),
              _Stat(label: '总资产', value: fmtMoney(m.assetsMinor, 'CNY')),
              _Stat(label: '本月支出', value: fmtMoney(expense, 'CNY'), color: y.expense),
              _Stat(label: '本月收入', value: fmtMoney(income, 'CNY'), color: y.income),
            ]),
            // 外币账户没折算：说一声，免得对着账户页加不起来
            if (m.excludedForeign.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('${m.excludedForeign.map((a) => a.name).join('、')} 不是人民币，没算进余额和总资产', style: theme.textTheme.bodySmall?.copyWith(color: y.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            // 寄语轮播：收入排位（低于三成的不在首页亮出来，财富页里有）+ 按处境挑的一池话，几秒换一句、点一下换一句
            if (cheerToneFor(m) != null) ...[
              const SizedBox(height: 10),
              CheerCarousel(m: m),
            ],
          ]),
        ),
      ),
    );
  }
}

/// 称号角标：称号是身份（贫困户 / 月光族 / …，净资产为负时是负翁那套），依据跟在后面（够花几个月 / 欠多少）；
/// 两段一个胶囊，称号加粗做主。负翁用警示色，别和「够花」混成一个调。
class _TitleBadge extends StatelessWidget {
  final WealthMetrics m;
  const _TitleBadge({required this.m});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final inDebt = m.inDebt;
    final color = inDebt ? y.danger : theme.colorScheme.primary;
    final title = m.title!;
    final basis = inDebt ? '欠 ${fmtMoney(-m.netWorthMinor, 'CNY')}' : '够花 ${m.runwayMonths!.toStringAsFixed(1)} 个月';
    return Semantics(
      label: inDebt ? '称号 $title，净资产 $basis' : '称号 $title，等级 ${m.level!.name}，$basis',
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 3, 10, 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: title, style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700, height: 1.1)),
            TextSpan(text: ' · $basis', style: theme.textTheme.labelSmall?.copyWith(color: color.withValues(alpha: 0.85))),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 目标条 + 本周任务：横向几张小卡；没有目标时给一个入口。
class _GoalsStrip extends StatelessWidget {
  const _GoalsStrip();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final goals = app.game.goals.where((p) => p.goal.kind != GoalKind.payoff || !p.reached).take(4).toList();
    final tasks = app.game.weekTasks;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (goals.isEmpty)
          GlassCard(
            child: ListTile(
              leading: Icon(Icons.flag_outlined, color: theme.colorScheme.primary),
              title: const Text('给钱一个用途'),
              subtitle: Text('换手机、买车、首付、一趟旅行——建一个目标，钱才有方向', style: theme.textTheme.bodySmall),
              trailing: Icon(Icons.chevron_right, color: y.muted),
              onTap: () => go(const GoalsPage()),
            ),
          )
        else
          // 一张通栏（多给一行 已攒 / 目标），两张平分，三张起才横滑（每张 46% 宽，露出下一张的边）
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            if (goals.length <= 2) {
              return Row(children: [
                for (var i = 0; i < goals.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: _GoalCard(p: goals[i], wide: goals.length == 1, onTap: () => go(const GoalsPage()))),
                ],
              ]);
            }
            final cardW = (w * 0.46).floorToDouble();
            // 横滑视口要铺到屏幕两边、而且不裁：卡片投影是 24 的模糊，视口只有卡片那么高、宽只到页边距，
            // 投影就被裁成一块贴着卡片的直角灰底（真机上很显眼）。OverflowBox 把页边距吃回来让视口和屏幕一样宽，
            // 列表自己留 _gutter 的内边距让卡片和上下的卡片对齐；Clip.none 让投影照常溢出去
            return SizedBox(
              height: 92,
              child: OverflowBox(
                minWidth: w + _gutter * 2,
                maxWidth: w + _gutter * 2,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.symmetric(horizontal: _gutter),
                  children: [
                    for (final p in goals)
                      Padding(padding: const EdgeInsets.only(right: 10), child: SizedBox(width: cardW, child: _GoalCard(p: p, wide: false, onTap: () => go(const GoalsPage())))),
                  ],
                ),
              ),
            );
          }),
        if (tasks.isNotEmpty) ...[
          const SizedBox(height: 10),
          GlassCard(
            child: InkWell(
              onTap: () => go(const TasksPage()),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('本周任务', style: theme.textTheme.bodySmall),
                  for (final t in tasks.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Icon(
                          (app.game.taskProgress[t.id]?.achieved ?? false) ? Icons.check_circle_outline : ((app.game.taskProgress[t.id]?.onTrack ?? true) ? Icons.radio_button_unchecked : Icons.error_outline),
                          size: 16,
                          color: (app.game.taskProgress[t.id]?.onTrack ?? true) ? theme.colorScheme.primary : y.danger,
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        Text(app.game.taskProgress[t.id]?.detail ?? '', style: theme.textTheme.bodySmall),
                      ]),
                    ),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// 首页目标小卡：emoji + 名字 + 进度条 + 一行数。[wide] 是首页只有一个目标时的通栏版：多放一行「已攒 / 目标」，别让一张小卡孤零零。
class _GoalCard extends StatelessWidget {
  final GoalProgress p;
  final bool wide;
  final VoidCallback onTap;
  const _GoalCard({required this.p, required this.wide, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final payoff = p.goal.kind == GoalKind.payoff;
    final tail = p.reached ? (payoff ? '还清了' : '攒够了') : '${payoff ? '还欠' : '还差'} ${fmtMoney(p.remainingMinor, p.goal.currency)}';
    return GlassCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(wide ? 16 : 12, 10, wide ? 16 : 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(p.goal.emoji ?? '🎯', style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Expanded(child: Text(p.goal.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: wide ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)),
              if (wide) Text('${(p.ratio * 100).toStringAsFixed(0)}%', style: theme.textTheme.titleMedium?.copyWith(color: p.reached ? y.income : theme.colorScheme.primary, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
            SizedBox(height: wide ? 10 : 12),
            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: p.ratio, minHeight: wide ? 8 : 6, backgroundColor: y.hairline, color: p.reached ? y.income : theme.colorScheme.primary)),
            const SizedBox(height: 4),
            if (wide)
              Row(children: [
                Expanded(child: Text('${payoff ? '已还' : '已攒'} ${fmtMoney(p.savedMinor, p.goal.currency)} / ${fmtMoney(p.targetMinor, p.goal.currency)}', style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text(tail, style: theme.textTheme.bodySmall, maxLines: 1),
              ])
            else
              Text('${(p.ratio * 100).toStringAsFixed(0)}% · $tail', style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}

/// 头卡的大字金额：一行，放不下（八位数以上 / 大字号）等比缩，不折行。
class _BigMoney extends StatelessWidget {
  final String text;
  final Color color;
  const _BigMoney(this.text, {required this.color});
  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(text, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 34, color: color, fontFeatures: const [FontFeature.tabularFigures()]), maxLines: 1, softWrap: false),
      );
}

/// 头卡下面那行小指标。以前三个 Expanded 各占三分之一，余额一到六位数（¥-399937.25）就比格子宽，数字被折成两行；
/// 现在每格按自己的内容宽、固定间距排开；三格加起来还是放不下（超大字号 / 窄屏）才整行等比缩小，数字永远一行、不截断。
/// （Flexible 不行：它给每格的上限还是三分之一，余额照样先缩。）
class _StatRow extends StatelessWidget {
  final List<Widget> children;
  const _StatRow({required this.children});
  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(width: children.length >= 4 ? 16 : 22), children[i]]], // 四格时间距收一点，少缩字
        ),
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Stat({required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.bodySmall, maxLines: 1, softWrap: false),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]), maxLines: 1, softWrap: false),
      ],
    );
  }
}
