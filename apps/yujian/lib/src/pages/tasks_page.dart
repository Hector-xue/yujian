import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../game/game_layer.dart';
import '../theme.dart';
import '../widgets/action_sheet.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';

/// 周任务：本周的（带实时进度）、候选（模板 + 模型提的，勾了才算）、过去几周的结算。
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app.game,
      builder: (context, _) {
        final game = app.game;
        final week = game.thisWeek;
        final history = app.ledger.tasks.list(limit: 60).where((t) => t.week != week).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('周任务'), actions: [
            IconButton(
              tooltip: '自己写一个',
              icon: const Icon(Icons.add),
              onPressed: () => _customTask(context),
            ),
          ]),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              Text('本周 ${week.substring(5).replaceFirst('-', '/')} 起 · 周日结算，判定全在本机看账本，做不到不扣任何东西。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
              const SizedBox(height: 10),
              if (game.weekTasks.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('本周还没有任务。从下面挑 1～3 个。', style: theme.textTheme.bodySmall)),
              for (final t in game.weekTasks) _TaskTile(task: t, progress: game.taskProgress[t.id]),
              if (game.candidates.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('候选', style: theme.textTheme.titleMedium),
                Text('${game.candidatesFromModel ? '按上周账本挑的（后面几个是模型提的，只进候选）。' : '按上周账本挑的。'}「＋」加入本周，点一下改数字，左滑不要。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                const SizedBox(height: 6),
                GlassCard(
                  child: Column(children: [
                    for (final c in game.candidates)
                      Dismissible(
                        key: ValueKey('candidate-${GameLayer.candidateKey(c)}'),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => game.dismissCandidate(c),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: y.muted.withValues(alpha: 0.15),
                          child: Icon(Icons.delete_outline, color: y.muted),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                          dense: true,
                          leading: Icon(_kindIcon(c.kind), size: 20, color: theme.colorScheme.primary),
                          title: Text(c.title),
                          subtitle: Text(_kindText(c.kind), style: theme.textTheme.bodySmall),
                          trailing: IconButton(tooltip: '加入本周', icon: const Icon(Icons.add_circle_outline), onPressed: () => _accept(context, c)),
                          onTap: () => _editCandidate(context, c),
                          onLongPress: () => _candidateMenu(context, c),
                        ),
                      ),
                  ]),
                ),
              ],
              if (history.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('过去几周', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                GlassCard(
                  child: Column(children: [
                    for (final t in history)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        dense: true,
                        leading: Icon(switch (t.result) { TaskResult.done => Icons.check_circle_outline, TaskResult.missed => Icons.remove_circle_outline, _ => Icons.schedule }, size: 20, color: t.result == TaskResult.done ? y.income : y.muted),
                        title: Text(t.title),
                        subtitle: Text('${t.week.substring(5).replaceFirst('-', '/')} 那周 · ${t.evidence?['detail'] ?? '未结算'}', style: theme.textTheme.bodySmall),
                      ),
                  ]),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static IconData _kindIcon(TaskKind k) => switch (k) {
        TaskKind.categoryCap => Icons.pie_chart_outline,
        TaskKind.countCap => Icons.repeat,
        TaskKind.noSpendDays => Icons.event_available_outlined,
        TaskKind.streakDays => Icons.local_fire_department_outlined,
        TaskKind.deposit => Icons.savings_outlined,
      };

  static String _kindText(TaskKind k) => switch (k) {
        TaskKind.categoryCap => '按分类合计判定',
        TaskKind.countCap => '按商户关键词计次',
        TaskKind.noSpendDays => '当天没有非固定支出算一天（房租等周期账单不算破功）',
        TaskKind.streakDays => '每天都有记录',
        TaskKind.deposit => '看往目标的存入',
      };

  /// 长按候选：编辑 / 不要。和别处的「更多」一样走底部动作单。
  Future<void> _candidateMenu(BuildContext context, TaskTemplate c) async {
    final game = AppScope.of(context).game;
    final r = await showActionSheet<String>(context, title: c.title, actions: const [
      SheetAction('add', '加入本周', icon: Icons.add_circle_outline),
      SheetAction('edit', '改一下再加入', icon: Icons.edit_outlined),
      SheetAction('dismiss', '不要这个（本周不再出现）', icon: Icons.delete_outline, danger: true),
    ]);
    if (r == null || !context.mounted) return;
    switch (r) {
      case 'add':
        await _accept(context, c);
      case 'edit':
        await _editCandidate(context, c);
      case 'dismiss':
        await game.dismissCandidate(c);
    }
  }

  /// 点候选：把它的类型 / 参数填进「自己写一个」的表单改，改完当新任务加入本周，原候选一并拿掉。
  Future<void> _editCandidate(BuildContext context, TaskTemplate c) async {
    final edited = await _composeTask(context, initial: c);
    if (edited == null || !context.mounted) return;
    await _accept(context, edited, replacing: c);
  }

  Future<void> _accept(BuildContext context, TaskTemplate c, {TaskTemplate? replacing}) async {
    final app = AppScope.of(context);
    final goals = app.game.goals.where((p) => p.goal.hasVault && !p.reached).toList();
    String? rewardGoal;
    final reward = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setSt) => AlertDialog(
          title: Text(c.title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('完成后奖励自己：往某个目标存一笔（真钱，从默认账户转到锁仓）。可不填。', style: Theme.of(d).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (goals.isNotEmpty) ...[
              PickerField<String?>(value: rewardGoal, decoration: const InputDecoration(labelText: '奖励存进'), items: [const DropdownMenuItem<String?>(value: null, child: Text('不奖励')), for (final g in goals) DropdownMenuItem<String?>(value: g.goal.id, child: Text(g.goal.name))], onChanged: (v) => setSt(() => rewardGoal = v)),
              const SizedBox(height: 8),
              TextField(controller: reward, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '奖励金额（元）'), enabled: rewardGoal != null),
            ],
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('加入本周'))],
        ),
      ),
    );
    if (ok != true) return;
    await app.game.acceptCandidate(c, replacing: replacing, rewardGoalId: rewardGoal, rewardMinor: rewardGoal == null ? 0 : ((int.tryParse(reward.text.trim()) ?? 0) * 100), source: app.game.candidatesFromModel ? 'model' : 'template');
  }

  Future<void> _customTask(BuildContext context) async {
    final r = await _composeTask(context);
    if (r == null || !context.mounted) return;
    await _accept(context, r);
  }

  /// 任务表单：空白（自己写一个）或带 [initial]（改候选）。返回填好的模板；取消 = null。
  /// 「往目标存」只在有锁仓目标（或就是在改一条存钱候选）时给选，存钱任务判定看的是往 vault 的存入，没锁仓无从判。
  Future<TaskTemplate?> _composeTask(BuildContext context, {TaskTemplate? initial}) async {
    final app = AppScope.of(context);
    final cats = app.categories.where((c) => c.kind == CategoryKind.expense).toList();
    final goals = app.game.goals.where((p) => p.goal.hasVault && !p.reached).map((p) => p.goal).toList();
    final initGoal = initial?.kind == TaskKind.deposit ? app.ledger.goals.find('${initial!.params['goal_id']}') : null;
    if (initGoal != null && !goals.any((g) => g.id == initGoal.id)) goals.add(initGoal);
    final canDeposit = goals.isNotEmpty;

    var kind = initial?.kind ?? TaskKind.categoryCap;
    if (kind == TaskKind.deposit && !canDeposit) kind = TaskKind.categoryCap;
    final initCat = initial?.kind == TaskKind.categoryCap ? '${initial!.params['category_id']}' : null;
    String? cat = cats.any((c) => c.id == initCat) ? initCat : (cats.isEmpty ? null : cats.first.id);
    String? goalId = initGoal?.id ?? (canDeposit ? goals.first.id : null);
    final numCtl = TextEditingController(text: _initialNumber(initial));
    final kw = TextEditingController(text: initial?.kind == TaskKind.countCap ? ((initial!.params['keywords'] as List?) ?? const []).map((k) => '$k').join(', ') : '');
    final r = await showDialog<TaskTemplate>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setSt) => AlertDialog(
          title: Text(initial == null ? '自己写一个任务' : '改一下这个任务'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              PickerField<TaskKind>(
                value: kind,
                decoration: const InputDecoration(labelText: '类型'),
                items: [
                  const DropdownMenuItem(value: TaskKind.categoryCap, child: Text('某分类本周不超过 N 元')),
                  const DropdownMenuItem(value: TaskKind.countCap, child: Text('某关键词本周不超过 N 次')),
                  const DropdownMenuItem(value: TaskKind.noSpendDays, child: Text('至少 N 个无消费日')),
                  const DropdownMenuItem(value: TaskKind.streakDays, child: Text('每天都记账')),
                  if (canDeposit) const DropdownMenuItem(value: TaskKind.deposit, child: Text('往某个目标存至少 N 元')),
                ],
                onChanged: (v) => setSt(() => kind = v ?? kind),
              ),
              const SizedBox(height: 8),
              if (kind == TaskKind.categoryCap) PickerField<String>(value: cat, decoration: const InputDecoration(labelText: '分类'), items: [for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.name))], onChanged: (v) => setSt(() => cat = v)),
              if (kind == TaskKind.deposit) PickerField<String>(value: goalId, decoration: const InputDecoration(labelText: '目标'), items: [for (final g in goals) DropdownMenuItem(value: g.id, child: Text(g.name))], onChanged: (v) => setSt(() => goalId = v)),
              if (kind == TaskKind.countCap) TextField(controller: kw, decoration: const InputDecoration(labelText: '关键词（逗号分开）', hintText: '美团, 饿了么')),
              if (kind != TaskKind.streakDays)
                TextField(
                  controller: numCtl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: switch (kind) { TaskKind.categoryCap => '上限（元）', TaskKind.countCap => '最多几次', TaskKind.deposit => '至少存（元）', _ => '至少几天' }),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(numCtl.text.trim()) ?? 0;
                final TaskTemplate t;
                switch (kind) {
                  case TaskKind.categoryCap:
                    if (n <= 0 || cat == null) return;
                    t = TaskTemplate(kind: kind, params: {'category_id': cat, 'cap_minor': n * 100}, title: '本周${app.categoryName(cat)}不超过 ¥$n');
                  case TaskKind.countCap:
                    final words = kw.text.split(RegExp('[,，、 ]+')).where((w) => w.trim().isNotEmpty).map((w) => w.trim()).toList();
                    if (n <= 0 || words.isEmpty) return;
                    t = TaskTemplate(kind: kind, params: {'keywords': words, 'max': n}, title: '本周${words.first}不超过 $n 次');
                  case TaskKind.noSpendDays:
                    if (n <= 0) return;
                    t = TaskTemplate(kind: kind, params: {'min_days': n}, title: '本周至少 $n 个无消费日');
                  case TaskKind.streakDays:
                    t = const TaskTemplate(kind: TaskKind.streakDays, params: {}, title: '本周每天都记账');
                  case TaskKind.deposit:
                    final g = goalId == null ? null : goals.where((g) => g.id == goalId).firstOrNull;
                    if (n <= 0 || g == null) return;
                    t = TaskTemplate(kind: kind, params: {'goal_id': g.id, 'min_minor': n * 100}, title: '本周往「${g.name}」存 ¥$n');
                }
                Navigator.pop(d, t);
              },
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
    return r;
  }

  /// 候选参数里的那个数（元 / 次 / 天）填进表单；模板里金额是分。
  static String _initialNumber(TaskTemplate? t) {
    if (t == null) return '';
    final p = t.params;
    final Object? v = switch (t.kind) {
      TaskKind.categoryCap => p['cap_minor'],
      TaskKind.countCap => p['max'],
      TaskKind.noSpendDays => p['min_days'],
      TaskKind.deposit => p['min_minor'],
      TaskKind.streakDays => null,
    };
    if (v is! num) return '';
    final n = (t.kind == TaskKind.categoryCap || t.kind == TaskKind.deposit) ? v ~/ 100 : v.toInt();
    return n <= 0 ? '' : '$n';
  }
}

class _TaskTile extends StatelessWidget {
  final WeeklyTask task;
  final TaskProgress? progress;
  const _TaskTile({required this.task, required this.progress});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final p = progress;
    final ratio = p == null || p.limit <= 0 ? 0.0 : (p.current / p.limit).clamp(0.0, 1.0);
    final capKind = task.kind == TaskKind.categoryCap || task.kind == TaskKind.countCap;
    final color = p == null ? y.muted : (capKind ? (p.onTrack ? theme.colorScheme.primary : y.danger) : (p.achieved ? y.income : theme.colorScheme.primary));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(task.title, style: theme.textTheme.titleSmall)),
              if (task.result == TaskResult.pending)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '放弃这个任务',
                  onPressed: () => app.game.removeTask(task.id),
                ),
            ]),
            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: ratio, minHeight: 6, backgroundColor: y.hairline, color: color)),
            const SizedBox(height: 4),
            Text('${p?.detail ?? ''}${capKind && p != null && !p.onTrack ? ' · 已超' : ''}${task.rewardGoalId != null && task.rewardMinor > 0 ? ' · 完成奖励 ${fmtMoney(task.rewardMinor, 'CNY')} → ${app.ledger.goals.find(task.rewardGoalId!)?.name ?? ''}' : ''}', style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}
