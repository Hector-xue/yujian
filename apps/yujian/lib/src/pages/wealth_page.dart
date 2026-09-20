import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';
import 'debts_page.dart';

/// 财富页：可花的 / 今天还能花 / 等级（生存月数）/ 储蓄率 / 净资产 / 收入线 / 成就，每个数都写清怎么来的；
/// 底部是游戏层的设置：发薪日、工资账户、总开关、代价行、三个仪式。
class WealthPage extends StatelessWidget {
  const WealthPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app.game,
      builder: (context, _) {
        final m = app.game.metrics;
        final game = app.game;
        Widget stat(String label, String value, String basis, {Color? color}) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: theme.textTheme.bodySmall),
                    Text(value, style: theme.textTheme.titleLarge?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()])),
                    Text(basis, style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                  ]),
                ),
              ),
            );
        return Scaffold(
          appBar: AppBar(title: const Text('财富')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              if (m == null)
                Padding(padding: const EdgeInsets.all(12), child: Text('正在算…', style: theme.textTheme.bodySmall))
              else ...[
                // 等级
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('等级', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      // 称号是身份、等级名是进度：称号做大字，等级名跟在后面。净资产为负：称号换成负翁那套（按欠款），等级名照旧
                      if (m.title == null)
                        Text('还没有数据', style: theme.textTheme.headlineMedium?.copyWith(fontSize: 30, color: theme.colorScheme.primary))
                      else
                        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                          Text(m.title!, style: theme.textTheme.headlineMedium?.copyWith(fontSize: 30, color: m.inDebt ? y.danger : theme.colorScheme.primary)),
                          const SizedBox(width: 8),
                          Text(m.level == null ? '净资产是负的' : m.level!.name, style: theme.textTheme.bodyMedium?.copyWith(color: y.muted)),
                        ]),
                      const SizedBox(height: 6),
                      if (m.debtTier != null) ...[
                        Text('净资产 ${fmtMoney(m.netWorthMinor, 'CNY')} = 资产 ${fmtMoney(m.assetsMinor, 'CNY')} − 负债 ${fmtMoney(m.debt.totalMinor, 'CNY')}，是负的：称号按欠的钱算，等级仍按够花几个月。', style: theme.textTheme.bodySmall),
                        Text(
                          m.debtTier!.lighter == null ? '再还 ${fmtMoney(m.toLighterDebtTierMinor!, 'CNY')} 净资产转正，摘掉「${m.debtTier!.title}」的帽子。' : '再还 ${fmtMoney(m.toLighterDebtTierMinor!, 'CNY')} 降到「${m.debtTier!.lighter!.title}」。',
                          style: theme.textTheme.bodySmall?.copyWith(color: y.danger),
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (m.level == null)
                        Text('等级 = 生存月数 = 流动资产 ÷ 月支出。记一笔收入或支出就有了，不用等一个月；也可以在下面直接填「每月大概花多少」。', style: theme.textTheme.bodySmall)
                      else ...[
                        Text('现在的钱够花 ${m.runwayMonths!.toStringAsFixed(1)} 个月 = 流动资产 ${fmtMoney(m.liquidMinor, 'CNY')} ÷ 月支出 ${fmtMoney(m.monthlySpendAvgMinor, 'CNY')}（${_basisLabel(m)}）。', style: theme.textTheme.bodySmall),
                        if (m.level!.next != null && m.toNextLevelMinor != null) Text('再攒 ${fmtMoney(m.toNextLevelMinor!, 'CNY')} 升到「${m.level!.next!.title}」（${m.level!.next!.name}，≥ ${m.level!.next!.minMonths.toStringAsFixed(m.level!.next!.minMonths % 1 == 0 ? 0 : 1)} 个月）。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                      ],
                      const SizedBox(height: 8),
                      if (m.debtTier != null) ...[
                        // 负翁阶梯：按欠款分档；下面那排等级仍然亮着自己那档（等级没变，只是称号被负翁顶掉）
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          for (final t in DebtTier.tiers)
                            Chip(
                              label: Text('${t.title} ${_tierRange(t)}', style: theme.textTheme.labelSmall),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: m.debtTier!.index == t.index ? y.danger.withValues(alpha: 0.15) : null,
                              side: BorderSide(color: m.debtTier!.index == t.index ? y.danger : y.hairline),
                            ),
                        ]),
                        const SizedBox(height: 6),
                      ],
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        for (final l in WealthLevel.levels)
                          Chip(
                            label: Text('${l.title} · ${l.name} ${l.maxMonths == null ? '≥ ${l.minMonths.toStringAsFixed(0)}' : '${l.minMonths.toStringAsFixed(l.minMonths % 1 == 0 ? 0 : 1)}–${l.maxMonths!.toStringAsFixed(0)}'} 月', style: theme.textTheme.labelSmall),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: m.level?.index == l.index ? theme.colorScheme.primary.withValues(alpha: 0.15) : null,
                            side: BorderSide(color: m.level?.index == l.index ? theme.colorScheme.primary : y.hairline),
                          ),
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                stat('可花的', fmtMoney(m.disposableMinor, 'CNY'), '= 流动资产 ${fmtMoney(m.liquidMinor, 'CNY')} − 锁进目标 ${fmtMoney(m.lockedMinor, 'CNY')} − 发薪前要付的固定支出和还贷 ${fmtMoney(m.fixedDueMinor, 'CNY')}${m.cardOwedMinor > 0 ? ' − 信用卡待还 ${fmtMoney(m.cardOwedMinor, 'CNY')}' : ''}${m.disposableMinor < 0 ? '。是负的：要付的比手头的钱多，发薪前得省着' : ''}', color: m.disposableMinor < 0 ? y.danger : y.balance),
                stat('今天还能花', fmtMoney(m.dailyAllowanceMinor, 'CNY'), '= 可花的 ÷ 到发薪日的 ${m.daysToPayday} 天。今天已花 ${fmtMoney(m.spentTodayMinor, 'CNY')}，已经从可花的里扣掉了，不再减一次。发薪日 ${m.payday}（${switch (m.paydaySource) { 'profile' => '你填的', 'inferred' => '从收入记录推的，可在下面改', _ => '没填也推不出，按月底算' }}）'),
                stat('净资产', fmtMoney(m.netWorthMinor, 'CNY'), '= 资产 ${fmtMoney(m.assetsMinor, 'CNY')} − 负债 ${fmtMoney(m.debt.totalMinor, 'CNY')}（目标锁仓算在资产里）${m.inDebt ? '。是负的很正常：有房贷车贷都这样，看下面的还清进度更有用' : ''}${m.excludedForeign.isNotEmpty ? '。${m.excludedForeign.map((a) => a.name).join('、')} 不是人民币，没算' : ''}', color: m.netWorthMinor < 0 ? y.danger : null),
                if (m.debt.totalMinor > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassCard(
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DebtsPage())),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('负债', style: theme.textTheme.bodySmall),
                                Text(fmtMoney(m.debt.totalMinor, 'CNY'), style: theme.textTheme.titleLarge?.copyWith(color: y.danger, fontFeatures: const [FontFeature.tabularFigures()])),
                                Text(
                                  [
                                    if (m.debt.loanMinor > 0) '贷款 ${fmtMoney(m.debt.loanMinor, 'CNY')}',
                                    if (m.debt.cardMinor > 0) '信用卡 ${fmtMoney(m.debt.cardMinor, 'CNY')}',
                                    if (m.debt.monthlyMinor > 0) '每月还 ${fmtMoney(m.debt.monthlyMinor, 'CNY')}',
                                    if (m.debt.monthsLeft != null && m.debt.monthsLeft! > 0) '约 ${m.debt.monthsLeft} 个月还清',
                                  ].join(' · '),
                                  style: theme.textTheme.bodySmall?.copyWith(color: y.muted),
                                ),
                              ]),
                            ),
                            Icon(Icons.chevron_right, color: y.muted),
                          ]),
                        ),
                      ),
                    ),
                  ),
                stat('本月储蓄率', m.savingsRate == null ? '—' : '${(m.savingsRate! * 100).toStringAsFixed(0)}%', m.savingsRate == null ? '本月还没有收入' : '= (收入 ${fmtMoney(m.monthIncomeMinor, 'CNY')} − 支出 ${fmtMoney(m.monthExpenseMinor, 'CNY')}) ÷ 收入；转账不算'),
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('本月收入线', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      _line(context, '主线', '工资 / 奖金', m.incomeByLine[IncomeLine.main] ?? 0),
                      _line(context, '副本', '兼职 / 礼金 / 外快', m.incomeByLine[IncomeLine.side] ?? 0),
                      _line(context, '挂机', '利息 / 分红 / 理财收益', m.incomeByLine[IncomeLine.passive] ?? 0),
                      if ((m.incomeByLine[IncomeLine.other] ?? 0) > 0) _line(context, '未归线', '其他收入', m.incomeByLine[IncomeLine.other]!),
                      Text('按收入分类归线；想改归属去「分类」页。多一条线，就少一分只靠月薪的紧。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text('成就', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('全部由账本事实触发，一次性；点开看依据。没有商店、没有签到。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
              const SizedBox(height: 8),
              // 成就一张卡、设置一张卡：和上面的指标卡一套
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final group in const [('goal', '目标'), ('saving', '攒钱'), ('habit', '习惯'), ('income', '收入'), ('debt', '负债'), ('record', '记录')]) ...[
                      Padding(padding: const EdgeInsets.fromLTRB(0, 8, 0, 2), child: Text(group.$2, style: theme.textTheme.labelLarge)),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final d in achievementDefs.where((d) => d.group == group.$1)) _AchievementChip(def: d, unlocked: game.achievements.where((a) => a.key == d.key).firstOrNull),
                      ]),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 22),
              Text('设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const _PaydayRow(),
              const SizedBox(height: 10),
              _MonthlyCostRow(metrics: m),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('财富游戏'),
                subtitle: Text('首页的「可花的 / 今天还能花 / 等级」、收件箱的代价行、三个仪式和成就提示。关掉首页恢复原样；目标页不受影响。', style: theme.textTheme.bodySmall),
                value: game.enabled,
                onChanged: game.setEnabled,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('收件箱代价行'),
                subtitle: Text('确认一笔支出时多一行小字：「这笔 = 日本游晚 4 天」。只显示，不拦。', style: theme.textTheme.bodySmall),
                value: game.costLine,
                onChanged: game.enabled ? game.setCostLine : null,
              ),
              for (final r in const [('payday', '发薪日仪式', '工资到账后一张卡：按目标顺序分钱，剩下多少可花，一键确认'), ('weekly', '周一任务卡', '结算上周，给本周 2～3 个任务候选'), ('monthly', '月末复盘', '进入新的一月第一次打开时，在对话里讲上个月发生了什么、目标近了多远、下个月改一件事')])
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.$2),
                  subtitle: Text(r.$3, style: theme.textTheme.bodySmall),
                  value: game.rituals[r.$1] ?? true,
                  onChanged: game.enabled ? (v) => game.setRitual(r.$1, v) : null,
                ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              Text('三个仪式都在你打开余见时触发（工资到账那一刻你确认了那笔收入也会触发）。余见不发系统通知，也不在后台跑。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
            ],
          ),
        );
      },
    );
  }

  /// 负翁档的欠款区间，整数万：「< 1 万」「1–10 万」「≥ 1000 万」。
  static String _tierRange(DebtTier t) {
    String wan(int minor) => '${minor ~/ 1000000} 万';
    final i = DebtTier.tiers.indexOf(t);
    final next = i + 1 < DebtTier.tiers.length ? DebtTier.tiers[i + 1] : null;
    if (t.floorMinor == 0) return '< ${wan(next!.floorMinor)}';
    if (next == null) return '≥ ${wan(t.floorMinor)}';
    return '${t.floorMinor ~/ 1000000}–${wan(next.floorMinor)}';
  }

  /// 月支出是按什么估的，一句话。
  static String _basisLabel(WealthMetrics m) => switch (m.spendBasis) {
        SpendBasis.manual => '你填的',
        SpendBasis.history => '近 ${m.monthsOfData} 个月平均，含每月还贷',
        SpendBasis.thisMonth => '本月到今天按天外推，记满一个月换成真实均值',
        SpendBasis.recurring => '还没记支出，按周期账单和还贷合计估',
        SpendBasis.income => '还没记满一个月，先按近一个月的收入当月支出（月光算法）；记满一个月换成真实均值，嫌不准可在下面手填',
        SpendBasis.none => '没数据',
      };

  Widget _line(BuildContext context, String name, String desc, int minor) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 44, child: Text(name, style: theme.textTheme.bodyMedium)),
        Expanded(child: Text(desc, style: theme.textTheme.bodySmall)),
        Text(fmtMoney(minor, 'CNY'), style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

class _AchievementChip extends StatelessWidget {
  final AchievementDef def;
  final Achievement? unlocked;
  const _AchievementChip({required this.def, required this.unlocked});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final on = unlocked != null;
    return ActionChip(
      avatar: Icon(on ? Icons.emoji_events : Icons.lock_outline, size: 16, color: on ? theme.colorScheme.primary : y.muted),
      label: Text(def.title, style: theme.textTheme.labelMedium?.copyWith(color: on ? null : y.muted)),
      side: BorderSide(color: on ? theme.colorScheme.primary : y.hairline),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(def.title),
          content: Text('${def.description}\n\n${on ? '达成于 ${fmtRelativeMs(unlocked!.unlockedAt)}${unlocked!.evidence == null ? '' : '\n依据：${unlocked!.evidence!.entries.map((e) => '${e.key} = ${e.value}').join('，')}'}' : '还没达成。'}'),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('好'))],
        ),
      ),
    );
  }
}

/// 「每月大概花多少」：手填就按手填的算等级，留空让指标自己估（估法写在旁边）。
class _MonthlyCostRow extends StatefulWidget {
  final WealthMetrics? metrics;
  const _MonthlyCostRow({required this.metrics});
  @override
  State<_MonthlyCostRow> createState() => _MonthlyCostRowState();
}

class _MonthlyCostRowState extends State<_MonthlyCostRow> {
  final _c = TextEditingController();
  var _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return; // 只在第一次把画像里的值填进输入框，之后以用户输入为准
    _loaded = true;
    final v = AppScope.of(context).ledger.profile.monthlyCostMinor;
    _c.text = v == null ? '' : Money(v, 'CNY').toDecimalString();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save() {
    final app = AppScope.of(context);
    final t = _c.text.trim();
    int? minor;
    if (t.isNotEmpty) {
      try {
        minor = Money.parse(t, 'CNY').minor;
      } on FormatException {
        minor = null;
      }
    }
    if (minor == app.ledger.profile.monthlyCostMinor) return;
    app.ledger.profile.monthlyCostMinor = minor;
    app.touch();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final auto = m == null || m.spendBasis == SpendBasis.none || m.spendBasis == SpendBasis.manual ? '留空 = 自动估' : '留空 = 自动估（现在按 ${fmtMoney(m.monthlySpendAvgMinor, 'CNY')}）';
    return Focus(
      onFocusChange: (has) {
        if (!has) _save();
      },
      child: TextField(
        controller: _c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: '每月大概花多少（元）', helperText: '算等级用；$auto'),
        onSubmitted: (_) => _save(),
      ),
    );
  }
}

/// 发薪日 + 工资账户：画像里的两项，指标要用。
class _PaydayRow extends StatelessWidget {
  const _PaydayRow();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final profile = app.ledger.profile;
    return Row(children: [
      Expanded(
        child: PickerField<int?>(
          value: profile.payday,
          decoration: const InputDecoration(labelText: '发薪日'),
          items: [const DropdownMenuItem<int?>(value: null, child: Text('自动推断')), for (var d = 1; d <= 31; d++) DropdownMenuItem<int?>(value: d, child: Text('每月 $d 号'))],
          onChanged: (v) {
            profile.payday = v;
            app.touch();
          },
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: PickerField<String?>(
          value: app.accounts.any((a) => a.id == profile.salaryAccountId) ? profile.salaryAccountId : null,
          decoration: const InputDecoration(labelText: '工资到哪个账户'),
          items: [const DropdownMenuItem<String?>(value: null, child: Text('不指定')), for (final a in app.accounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name, style: theme.textTheme.bodyMedium))],
          onChanged: (v) {
            profile.salaryAccountId = v;
            app.touch();
          },
        ),
      ),
    ]);
  }
}
