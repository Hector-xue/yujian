import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';
import 'goal_detail_page.dart';

/// 目标列表：心愿 / 应急金 / 还清 / 里程碑，一张卡一个进度条。拖动排序 = 发薪日分钱的优先级。
class GoalsPage extends StatelessWidget {
  const GoalsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    return ListenableBuilder(
      listenable: app.game,
      builder: (context, _) {
        final goals = app.game.goals;
        final archived = app.ledger.goals.list(activeOnly: false).where((g) => g.status != GoalStatus.active).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('目标')),
          floatingActionButton: FloatingActionButton.extended(onPressed: () => showGoalForm(context), icon: const Icon(Icons.add), label: const Text('新目标')),
          body: goals.isEmpty && archived.isEmpty
              ? _Empty(onCreate: () => showGoalForm(context))
              : ReorderableListView(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 96 + MediaQuery.paddingOf(context).bottom),
                  header: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('顺序就是发薪日分钱的先后：钱不够时先保上面的。长按拖动。', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ),
                  footer: archived.isEmpty
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('已完成 / 已归档', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                            for (final g in archived)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                leading: Text(g.emoji ?? '🎯', style: const TextStyle(fontSize: 22)),
                                title: Text(g.name),
                                subtitle: Text('${g.status == GoalStatus.done ? '已达成' : '已归档'} · ${fmtMoney(g.targetMinor, g.currency)}', style: theme.textTheme.bodySmall),
                                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GoalDetailPage(goalId: g.id))),
                              ),
                          ]),
                        ),
                  onReorder: (from, to) {
                    final ids = goals.map((p) => p.goal.id).toList();
                    final id = ids.removeAt(from);
                    ids.insert(to > from ? to - 1 : to, id);
                    app.game.reorderGoals(ids);
                  },
                  children: [for (final p in goals) GoalCard(key: ValueKey(p.goal.id), progress: p)],
                ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  final VoidCallback onCreate;
  const _Empty({required this.onCreate});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 40, 28, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('🎯', style: TextStyle(fontSize: 44)),
        const SizedBox(height: 12),
        Text('给钱一个用途', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('游戏里攒币是因为攒够了能买那把剑。换手机、买车、首付、一趟旅行——写下来，钱才有方向。存进去的钱会从「可花的」里划走，攒够了从这里花出去。', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onCreate, icon: const Icon(Icons.add), label: const Text('建第一个目标')),
      ]),
    );
  }
}

/// 一张目标卡：emoji、名字、进度条、已攒 / 目标、按速度还要多久。
class GoalCard extends StatelessWidget {
  final GoalProgress progress;
  const GoalCard({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final p = progress;
    final g = p.goal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GoalDetailPage(goalId: g.id))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(g.emoji ?? _kindEmoji(g.kind), style: const TextStyle(fontSize: 26)),
                const SizedBox(width: 10),
                Expanded(child: Text(g.name, style: theme.textTheme.titleMedium)),
                Text('${(p.ratio * 100).toStringAsFixed(0)}%', style: theme.textTheme.titleMedium?.copyWith(color: p.reached ? y.income : theme.colorScheme.primary, fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: p.ratio, minHeight: 8, backgroundColor: y.hairline, color: p.reached ? y.income : theme.colorScheme.primary),
              ),
              const SizedBox(height: 8),
              Text(app.game.describe(p).replaceFirst(RegExp(r'^[^：]*：'), ''), style: theme.textTheme.bodySmall),
              if (g.kind == GoalKind.wish && g.deadline != null) Text('期限 ${g.deadline}', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
            ]),
          ),
        ),
      ),
    );
  }

  static String _kindEmoji(GoalKind k) => switch (k) { GoalKind.wish => '🎯', GoalKind.emergency => '🛟', GoalKind.payoff => '🧾', GoalKind.milestone => '🏔️' };
}

/// 心愿模板：常见的几样，带典型价位和拆项提示。
class _WishTemplate {
  final String emoji;
  final String name;
  final int amountMinor;
  final String? hint;
  const _WishTemplate(this.emoji, this.name, this.amountMinor, [this.hint]);
}

const _wishTemplates = [
  _WishTemplate('📱', '换手机', 699900),
  _WishTemplate('💻', '换电脑', 999900),
  _WishTemplate('✈️', '一次旅行', 1200000, '机票 + 住宿 + 当地花销'),
  _WishTemplate('🚗', '买车', 15000000, '裸车 + 购置税（约 8.85%）+ 保险 + 上牌'),
  _WishTemplate('🏠', '首付', 50000000, '总价 × 首付比例 + 税费 + 中介费'),
  _WishTemplate('💍', '结婚', 10000000),
  _WishTemplate('🛋️', '装修', 8000000),
  _WishTemplate('📚', '学习 / 考证', 500000),
];

/// 建目标：三步——要什么 → 多少钱、什么时候 → 怎么攒。全部本机。
Future<Goal?> showGoalForm(BuildContext context, {Goal? edit}) => showModalBottomSheet<Goal>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom), child: _GoalForm(edit: edit)),
    );

class _GoalForm extends StatefulWidget {
  final Goal? edit;
  const _GoalForm({this.edit});
  @override
  State<_GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends State<_GoalForm> {
  var kind = GoalKind.wish;
  final name = TextEditingController();
  final emoji = TextEditingController(text: '🎯');
  final amount = TextEditingController();
  final monthly = TextEditingController();
  final pct = TextEditingController();
  String? deadline;
  var roundup = false;
  String? vaultAccountId; // null = 虚拟锁仓
  String? linkedAccountId;
  int emergencyMonths = 3;
  String? note;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    if (e != null) {
      kind = e.kind;
      name.text = e.name;
      emoji.text = e.emoji ?? '🎯';
      amount.text = (e.targetMinor / 100).toStringAsFixed(e.targetMinor % 100 == 0 ? 0 : 2);
      deadline = e.deadline;
      vaultAccountId = e.isVirtualVault ? null : e.vaultAccountId;
      linkedAccountId = e.linkedAccountId;
      for (final r in e.rules) {
        if (r.kind == GoalRuleKind.fixed && r.every == 'monthly') monthly.text = '${r.amountMinor ~/ 100}';
        if (r.kind == GoalRuleKind.salaryPct) pct.text = r.pct.toStringAsFixed(r.pct % 1 == 0 ? 0 : 1);
        if (r.kind == GoalRuleKind.roundup) roundup = true;
      }
    }
  }

  @override
  void dispose() {
    for (final c in [name, emoji, amount, monthly, pct]) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _amountMinor {
    final v = double.tryParse(amount.text.trim().replaceAll(',', ''));
    return v == null || v <= 0 ? null : (v * 100).round();
  }

  List<GoalRule> _rules() => [
        if ((int.tryParse(monthly.text.trim()) ?? 0) > 0) GoalRule(kind: GoalRuleKind.fixed, amountMinor: int.parse(monthly.text.trim()) * 100, every: 'monthly', day: AppScope.of(context).ledger.profile.payday ?? 1),
        if ((double.tryParse(pct.text.trim()) ?? 0) > 0) GoalRule(kind: GoalRuleKind.salaryPct, pct: double.parse(pct.text.trim()).clamp(0, 100)),
        if (roundup) const GoalRule(kind: GoalRuleKind.roundup, roundTo: 1000),
      ];

  /// 按每月定额算一个"大约什么时候攒够"。
  String? _eta() {
    final a = _amountMinor;
    final m = int.tryParse(monthly.text.trim()) ?? 0;
    if (a == null || m <= 0) return null;
    final months = (a / (m * 100)).ceil();
    final d = DateTime.now();
    final eta = DateTime(d.year, d.month + months, d.day);
    return '每月 $m，大约 $months 个月，${eta.year} 年 ${eta.month} 月攒够';
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    final nav = Navigator.of(context);
    try {
      int target;
      if (kind == GoalKind.emergency) {
        final avg = app.game.metrics?.monthlySpendAvgMinor ?? 0;
        target = avg > 0 ? avg * emergencyMonths : (_amountMinor ?? 0);
        if (target <= 0) throw '还没有足够的支出记录来算月支出，先填一个目标金额';
        if (name.text.trim().isEmpty) name.text = '应急金（$emergencyMonths 个月）';
      } else if (kind == GoalKind.payoff) {
        if (linkedAccountId == null) throw '选一个信用卡 / 应付类账户';
        target = 0;
        if (name.text.trim().isEmpty) name.text = '还清${app.accountName(linkedAccountId)}';
      } else {
        target = _amountMinor ?? (throw '填一个目标金额');
      }
      if (name.text.trim().isEmpty) throw '给它起个名字';
      final e = widget.edit;
      final Goal g;
      if (e != null) {
        g = await app.game.updateGoal(e.id, name: name.text.trim(), emoji: emoji.text.trim().isEmpty ? null : emoji.text.trim(), targetMinor: kind == GoalKind.payoff ? null : target, deadline: deadline, clearDeadline: deadline == null, rules: _rules());
      } else {
        g = await app.game.createGoal(
          kind: kind,
          name: name.text.trim(),
          targetMinor: target,
          emoji: emoji.text.trim().isEmpty ? null : emoji.text.trim(),
          deadline: deadline,
          vaultAccountId: vaultAccountId,
          linkedAccountId: linkedAccountId,
          rules: _rules(),
          withVault: kind != GoalKind.payoff,
        );
      }
      nav.pop(g);
    } catch (x) {
      setState(() => note = x is LedgerException ? x.message : '$x');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    final accounts = app.accounts;
    final debtAccounts = accounts.where((a) => a.type == AccountType.creditCard || a.type == AccountType.payable).toList();
    final avg = app.game.metrics?.monthlySpendAvgMinor ?? 0;
    final eta = _eta();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.edit == null ? '新目标' : '编辑目标', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        if (widget.edit == null) ...[
          Text('① 要什么', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final k in GoalKind.values)
              ChoiceChip(
                label: Text(switch (k) { GoalKind.wish => '心愿', GoalKind.emergency => '应急金', GoalKind.payoff => '还清', GoalKind.milestone => '净资产里程碑' }),
                selected: kind == k,
                onSelected: (_) => setState(() => kind = k),
              ),
          ]),
          const SizedBox(height: 8),
          if (kind == GoalKind.wish)
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final t in _wishTemplates)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text('${t.emoji} ${t.name}'),
                      onPressed: () => setState(() {
                        name.text = t.name;
                        emoji.text = t.emoji;
                        amount.text = '${t.amountMinor ~/ 100}';
                        note = t.hint;
                      }),
                    ),
                  ),
              ]),
            ),
          if (kind == GoalKind.emergency) ...[
            Text('应急金 = N 个月的日常支出。按最近 3 个月平均${avg > 0 ? '（${fmtMoney(avg, 'CNY')} / 月）' : '（还没有数据）'}算，创建后金额冻结，以后可改。', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            Wrap(spacing: 8, children: [for (final n in [1, 3, 6, 12]) ChoiceChip(label: Text('$n 个月'), selected: emergencyMonths == n, onSelected: (_) => setState(() => emergencyMonths = n))]),
          ],
          if (kind == GoalKind.payoff) ...[
            Text('只能选信用卡 / 应付类账户，进度跟着它的余额走。准不准取决于你有没有把刷卡消费记在这个账户上。', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            if (debtAccounts.isEmpty) Text('还没有信用卡 / 应付类账户，先到「账户」里建一个。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            PickerField<String>(
              value: linkedAccountId,
              decoration: const InputDecoration(labelText: '负债账户'),
              items: [for (final a in debtAccounts) DropdownMenuItem(value: a.id, child: Text('${a.name}（欠 ${fmtMoney(-app.ledger.balance(a.id).minor, a.currency)}）'))],
              onChanged: (v) => setState(() => linkedAccountId = v),
            ),
          ],
          const SizedBox(height: 8),
        ],
        Row(children: [
          SizedBox(width: 64, child: TextField(controller: emoji, decoration: const InputDecoration(labelText: '图标'), textAlign: TextAlign.center)),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: name, decoration: InputDecoration(labelText: '名字', hintText: kind == GoalKind.wish ? '换手机 / 去日本 / 首付' : null))),
        ]),
        if (kind != GoalKind.payoff && kind != GoalKind.emergency) ...[
          const SizedBox(height: 14),
          Text('② 多少钱、什么时候', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '目标金额（元）'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(deadline == null ? '不设期限' : '期限 $deadline', style: theme.textTheme.bodyMedium)),
            TextButton(
              onPressed: () async {
                final d = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365 * 10)), initialDate: deadline == null ? DateTime.now().add(const Duration(days: 180)) : DateTime.parse(deadline!));
                if (d != null) setState(() => deadline = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
              },
              child: const Text('选日期'),
            ),
            if (deadline != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => deadline = null)),
          ]),
        ],
        if (kind != GoalKind.payoff) ...[
          const SizedBox(height: 14),
          Text('③ 怎么攒（可多选，都可以不填）', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: TextField(controller: monthly, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '每月定存（元）'), onChanged: (_) => setState(() {}))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: pct, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '工资到账后存 %'))),
          ]),
          SwitchListTile(contentPadding: EdgeInsets.zero, dense: true, title: const Text('零头凑整'), subtitle: Text('每笔支出凑到整十元，零头周末一次存进来（记 28 → 存 2）', style: theme.textTheme.bodySmall), value: roundup, onChanged: (v) => setState(() => roundup = v)),
          if (eta != null) Text(eta, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          if (widget.edit == null) ...[
            const SizedBox(height: 8),
            PickerField<String?>(
              value: vaultAccountId,
              title: '钱放哪',
              decoration: const InputDecoration(labelText: '钱放哪'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('虚拟锁仓（钱不动，只从「可花的」里划走）')),
                for (final a in accounts) DropdownMenuItem<String?>(value: a.id, child: Text('真的转到「${a.name}」')),
              ],
              onChanged: (v) => setState(() => vaultAccountId = v),
            ),
            Text(vaultAccountId == null ? '默认。存入只是标记，不用真的转账；首页「可花的」立刻变少。' : '每次存入会进收件箱，你去银行 / 余额宝真转了再点确认（余见不会替你转钱）。', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
        ],
        if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: Text(widget.edit == null ? '建好' : '保存')),
      ]),
    );
  }
}
