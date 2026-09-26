import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/action_sheet.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';
import 'goals_page.dart';
import 'inbox_page.dart';

/// 目标详情：进度与依据、存入 / 兑现 / 完成 / 归档、规则、存入记录。
class GoalDetailPage extends StatelessWidget {
  final String goalId;
  const GoalDetailPage({super.key, required this.goalId});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app.game,
      builder: (context, _) {
        final g = app.ledger.goals.find(goalId);
        if (g == null) return const Scaffold(body: Center(child: Text('目标不存在了')));
        final p = app.game.progressOf(g.id) ?? app.ledger.goals.progress(g, today: todayLocal(), liquidMinor: app.game.metrics?.freeLiquidMinor, netWorthMinor: app.game.metrics?.netWorthMinor);
        final active = g.status == GoalStatus.active;
        final deposits = g.hasVault ? app.ledger.goals.deposits(g.id, limit: 30) : const <Transaction>[];
        final redemptions = g.hasVault ? app.ledger.goals.redemptions(g.id, limit: 30) : const <Transaction>[];
        final vault = g.vaultAccountId == null ? null : app.ledger.account(g.vaultAccountId!);
        return Scaffold(
          appBar: AppBar(title: Text(g.name), actions: [
            if (active) IconButton(tooltip: '编辑', icon: const Icon(Icons.edit_outlined), onPressed: () => showGoalForm(context, edit: g)),
            IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz),
              onPressed: () async {
                final nav = Navigator.of(context);
                final v = await showActionSheet<String>(context, title: g.name, actions: [
                  if (active) const SheetAction('complete', '标记达成', icon: Icons.check_circle_outline),
                  if (active) const SheetAction('archive', '归档', icon: Icons.inventory_2_outlined),
                  if (!active) const SheetAction('reactivate', '重新开始', icon: Icons.replay_outlined),
                  const SheetAction('delete', '删除', icon: Icons.delete_outline, danger: true),
                ]);
                if (v == null || !context.mounted) return;
                if (v == 'complete') {
                  final ok = await _confirm(context, '标记为已达成？', g.isVirtualVault && p.savedMinor > 0 ? '锁仓里还有 ${fmtMoney(p.savedMinor, g.currency)}，会按存入来源比例释放回「可花的」。' : '目标会移到已完成。');
                  if (!ok) return;
                  await app.game.complete(g);
                } else if (v == 'archive') {
                  final ok = await _confirm(context, '归档这个目标？', g.isVirtualVault && p.savedMinor > 0 ? '锁仓里的 ${fmtMoney(p.savedMinor, g.currency)} 会释放回来源账户。' : (g.hasVault && !g.isVirtualVault ? '钱还在「${vault?.name ?? ''}」里，只是不再算作锁定。' : '目标会移到已归档。'));
                  if (!ok) return;
                  await app.game.archive(g);
                } else if (v == 'reactivate') {
                  app.ledger.goals.update(g.id, status: GoalStatus.active);
                  app.touch();
                  return;
                } else if (v == 'delete') {
                  // 删 ≠ 归档：目标从列表里消失、不进「已归档」。锁仓里的钱先回来源；锁仓账户没记录真删、存过钱归档（历史对得上）
                  final saved = g.isVirtualVault ? p.savedMinor : 0;
                  final ok = await _confirm(
                    context,
                    '删除这个目标？',
                    [
                      if (saved > 0) '锁仓里的 ${fmtMoney(saved, g.currency)} 会先释放回来源账户。',
                      if (g.kind == GoalKind.payoff) '只删还清目标，负债本身还在（要一起删去「负债」页）。',
                      g.isVirtualVault && deposits.isNotEmpty ? '存入记录留着（锁仓账户归档），目标本身删掉，不进「已归档」。' : '删了就没了，不进「已归档」。',
                    ].join(''),
                  );
                  if (!ok) return;
                  await app.game.deleteGoal(g);
                }
                if (nav.canPop()) nav.pop();
              },
            ),
          ]),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(g.emoji ?? '🎯', style: const TextStyle(fontSize: 40)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(fmtMoney(p.savedMinor, g.currency), style: theme.textTheme.headlineMedium?.copyWith(fontSize: 30, color: p.reached ? y.income : theme.colorScheme.primary, fontFeatures: const [FontFeature.tabularFigures()])),
                          Text('/ ${fmtMoney(p.targetMinor, g.currency)} · ${(p.ratio * 100).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: p.ratio, minHeight: 10, backgroundColor: y.hairline, color: p.reached ? y.income : theme.colorScheme.primary)),
                    const SizedBox(height: 10),
                    Text(app.game.describe(p).replaceFirst(RegExp(r'^[^：]*：'), ''), style: theme.textTheme.bodyMedium),
                    if (g.deadline != null) Text('期限 ${g.deadline}${p.behindDays != null ? (p.behindDays! > 0 ? ' · 按现在的速度晚 ${p.behindDays} 天' : ' · 按现在的速度提前 ${-p.behindDays!} 天') : ''}', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                    const SizedBox(height: 6),
                    Text(_basis(g, p, vault, app.accountName(g.linkedAccountId)), style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                  ]),
                ),
              ),
              if (active && g.hasVault) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: FilledButton.icon(onPressed: () => _depositSheet(context, g), icon: const Icon(Icons.savings_outlined, size: 18), label: const Text('存一笔'))),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton.icon(onPressed: p.savedMinor <= 0 ? null : () => _redeemSheet(context, g, p), icon: const Icon(Icons.shopping_bag_outlined, size: 18), label: const Text('花在它上'))),
                ]),
                if (!g.isVirtualVault) Padding(padding: const EdgeInsets.only(top: 6), child: Text('真锁仓：每次存入会进收件箱，你去「${vault?.name ?? ''}」真转了再确认。余见不会替你转钱。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted))),
              ],
              const SizedBox(height: 18),
              Text('怎么攒', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              if (g.rules.isEmpty)
                Text(g.kind == GoalKind.payoff ? '往这个账户还款就是进度。' : '还没设规则。点右上角编辑，可以设每月定存、工资到账比例、零头凑整。', style: theme.textTheme.bodySmall)
              else
                for (final r in g.rules) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('• ${_ruleText(r, g)}', style: theme.textTheme.bodyMedium)),
              if (g.kind != GoalKind.payoff) ...[
                const SizedBox(height: 18),
                Text('钱放哪', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(g.isVirtualVault ? '虚拟锁仓：钱没动，只是从「可花的」里划走了 ${fmtMoney(p.savedMinor, g.currency)}。' : '真锁仓：「${vault?.name ?? ''}」，余额 ${vault == null ? '—' : fmtMoney(app.ledger.balance(vault.id).minor, vault.currency)}。', style: theme.textTheme.bodyMedium),
                if (active)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(onPressed: () => _switchVault(context, g, p), icon: const Icon(Icons.swap_horiz, size: 18), label: Text(g.isVirtualVault ? '改成真的转到某个账户' : '改回虚拟锁仓')),
                  ),
              ],
              if (deposits.isNotEmpty || redemptions.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('记录', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                for (final t in [...deposits, ...redemptions]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(t.type == TransactionType.expense ? Icons.shopping_bag_outlined : (t.toAccountId == g.vaultAccountId ? Icons.arrow_downward : Icons.arrow_upward), size: 18),
                    title: Text(t.description ?? (t.type == TransactionType.expense ? '兑现' : '存入')),
                    subtitle: Text('${fmtDate(t.occurredAt.localDate, today: todayLocal())} · ${t.type == TransactionType.expense ? app.accountName(g.vaultAccountId) : (t.toAccountId == g.vaultAccountId ? '来自 ${app.accountName(t.accountId)}' : '回到 ${app.accountName(t.toAccountId)}')}', style: theme.textTheme.bodySmall),
                    trailing: Text('${t.type == TransactionType.expense || t.accountId == g.vaultAccountId ? '−' : '+'}${fmtMoney(t.amountMinor, t.currency)}', style: theme.textTheme.titleSmall),
                    onLongPress: () async {
                      final ok = await _confirm(context, '作废这一笔？', '作废后余额会退回。');
                      if (ok) app.voidTransaction(t.id, '目标页作废');
                    },
                  ),
                Text('长按一条可作废', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _basis(Goal g, GoalProgress p, Account? vault, String linkedName) => switch (g.kind) {
        GoalKind.wish => '依据：锁仓账户「${vault?.name ?? g.name}」的余额 ÷ 目标额。最近 30 天存入 ${p.paceMinorPerDay == null ? '为 0，算不出速度' : '平均每天 ${fmtMoney(p.paceMinorPerDay!.round(), g.currency)}'}。',
        GoalKind.emergency => '依据：${g.hasVault ? '锁仓余额' : '没锁进别的目标的流动资产'} ÷ 目标额（创建时按近 3 个月平均月支出 × N 冻结）。',
        GoalKind.payoff => '依据：「$linkedName」的欠款从建目标时的 ${fmtMoney(g.targetMinor, g.currency)} 降到了多少${p.targetMinor > g.targetMinor ? '（现在欠的比建目标时还多，按现在的 ${fmtMoney(p.targetMinor, g.currency)} 算）' : ''}。',
        GoalKind.milestone => '依据：净资产（全部账户余额之和，信用卡 / 应付为负）÷ 目标额。',
      };

  static String _ruleText(GoalRule r, Goal g) => switch (r.kind) {
        GoalRuleKind.fixed => '每${r.every == 'weekly' ? '周' : '月'} ${r.every == 'weekly' ? '周${'一二三四五六日'[r.day.clamp(1, 7) - 1]}' : '${r.day} 号'}定存 ${fmtMoney(r.amountMinor, g.currency)}（虚拟锁仓直接记；真锁仓进收件箱）',
        GoalRuleKind.salaryPct => '工资到账后存 ${r.pct.toStringAsFixed(r.pct % 1 == 0 ? 0 : 1)}%（发薪日一张卡确认）',
        GoalRuleKind.roundup => '零头凑整到 ${r.roundTo ~/ 100} 元，每周一结一次',
        GoalRuleKind.reward => '周任务完成奖励 ${fmtMoney(r.amountMinor, g.currency)}',
      };

  static Future<bool> _confirm(BuildContext context, String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('确定'))],
      ),
    );
    return r ?? false;
  }

  Future<void> _depositSheet(BuildContext context, Goal g) async {
    final app = AppScope.of(context);
    final amount = TextEditingController();
    String? from = app.ledger.profile.salaryAccountId ?? app.defaultAccountId;
    final r = await showModalBottomSheet<(int, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('往「${g.name}」存一笔', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(controller: amount, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '金额（元）')),
            const SizedBox(height: 8),
            PickerField<String>(value: from, decoration: const InputDecoration(labelText: '从哪个账户'), items: [for (final a in app.accounts) DropdownMenuItem(value: a.id, child: Text('${a.name}（${fmtMoney(app.ledger.balance(a.id).minor, a.currency)}）'))], onChanged: (v) => setSt(() => from = v)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(amount.text.trim());
                if (v == null || v <= 0 || from == null) return;
                Navigator.pop(ctx, ((v * 100).round(), from!));
              },
              child: Text(g.isVirtualVault ? '存入' : '进收件箱（真转了再确认）'),
            ),
          ]),
        ),
      ),
    );
    if (r == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final d = await app.game.deposit(g, r.$1, fromAccountId: r.$2);
    if (!context.mounted) return;
    if (d != null) {
      messenger.showSnackBar(SnackBar(content: const Text('已进收件箱：去银行 / 余额宝真转了再确认'), action: SnackBarAction(label: '去收件箱', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const InboxPage())))));
    }
  }

  Future<void> _redeemSheet(BuildContext context, Goal g, GoalProgress p) async {
    final app = AppScope.of(context);
    final amount = TextEditingController(text: '${p.savedMinor ~/ 100}');
    final merchant = TextEditingController();
    final cats = app.categories.where((c) => c.kind == CategoryKind.expense).toList();
    String? cat = cats.any((c) => c.id == 'shopping') ? 'shopping' : cats.first.id;
    final r = await showModalBottomSheet<(int, String, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('把钱花在「${g.name}」上', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('记一笔从锁仓账户出去的支出。可以分几次记（机票、酒店……）；全花完或点「标记达成」结束。锁仓里有 ${fmtMoney(p.savedMinor, g.currency)}，买贵了的部分另外从平时的账户记。', style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '金额（元）')),
            const SizedBox(height: 8),
            TextField(controller: merchant, decoration: const InputDecoration(labelText: '商户 / 说明（可不填）')),
            const SizedBox(height: 8),
            PickerField<String>(value: cat, decoration: const InputDecoration(labelText: '分类'), items: [for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.name))], onChanged: (v) => setSt(() => cat = v)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(amount.text.trim());
                if (v == null || v <= 0 || cat == null) return;
                Navigator.pop(ctx, ((v * 100).round(), cat!, merchant.text.trim()));
              },
              child: const Text('记这笔'),
            ),
          ]),
        ),
      ),
    );
    if (r == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.game.redeem(g, r.$1, categoryId: r.$2, merchant: r.$3.isEmpty ? null : r.$3);
      messenger.showSnackBar(const SnackBar(content: Text('记好了。花完了记得「标记达成」')));
    } on LedgerException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _switchVault(BuildContext context, Goal g, GoalProgress p) async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (g.isVirtualVault) {
      String? to;
      final picked = await showDialog<String>(
        context: context,
        builder: (d) => StatefulBuilder(
          builder: (d, setSt) => AlertDialog(
            title: const Text('改成真锁仓'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('已锁的 ${fmtMoney(p.savedMinor, g.currency)} 会变成一笔「转到那个账户」的草稿进收件箱，你真转了再确认。以后每次存入也都要确认。', style: Theme.of(d).textTheme.bodySmall),
              const SizedBox(height: 8),
              PickerField<String>(
                value: to,
                decoration: const InputDecoration(labelText: '转到'),
                items: [for (final a in app.accounts) if (a.currency == g.currency && GoalStore.canBeVault(a.type)) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => setSt(() => to = v),
              ),
              if (to != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('「${app.accountName(to)}」里现有的 ${fmtMoney(app.ledger.balance(to!).minor, g.currency)} 也会算作已攒，最好用一个专门存这笔钱的账户。', style: Theme.of(d).textTheme.bodySmall),
                ),
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')), FilledButton(onPressed: to == null ? null : () => Navigator.pop(d, to), child: const Text('改'))],
          ),
        ),
      );
      if (picked == null || !context.mounted) return;
      // 先把虚拟 vault 的钱释放回来源，再把目标指向真实账户，再提一笔转账草稿
      await app.game.release(g, silent: true);
      final ng = app.ledger.goals.setVault(g.id, picked);
      if (p.savedMinor > 0) await app.game.deposit(ng, p.savedMinor, note: '改为真锁仓：把已锁的钱转过去');
      app.touch();
      messenger.showSnackBar(SnackBar(content: Text(p.savedMinor > 0 ? '已进收件箱：真转到「${app.accountName(picked)}」后确认' : '已改为真锁仓')));
    } else {
      final ok = await _confirm(context, '改回虚拟锁仓？', '钱留在「${app.accountName(g.vaultAccountId)}」里不动；目标会新建一个虚拟锁仓，从 0 开始标记（已经攒的那部分请手动存入）。');
      if (!ok || !context.mounted) return;
      app.ledger.goals.setVault(g.id, null);
      app.touch();
    }
  }
}
