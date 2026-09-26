import 'dart:convert';

import 'changes.dart';
import 'db/database.dart';
import 'goals.dart';
import 'ledger.dart';
import 'models/enums.dart';
import 'tasks.dart';
import 'wealth.dart';

/// 一个成就的定义：key 稳定不变；check 只看账本事实，返回 null = 没达成，否则是「依据」。
class AchievementDef {
  final String key;
  final String group; // goal | saving | habit | income | debt | record
  final String title;
  final String description;
  final Map<String, Object?>? Function(AchievementContext ctx) check;
  const AchievementDef({required this.key, required this.group, required this.title, required this.description, required this.check});
}

/// check 用到的账本快照，一次算好给所有定义共用。
class AchievementContext {
  final Ledger ledger;
  final WealthMetrics metrics;
  final String today;
  final List<GoalProgress> goals;
  final List<WeeklyTask> settledTasks; // 最近的已结算任务（新在前）
  const AchievementContext({required this.ledger, required this.metrics, required this.today, required this.goals, required this.settledTasks});
}

class Achievement {
  final String key;
  final int unlockedAt;
  final Map<String, Object?>? evidence;
  const Achievement({required this.key, required this.unlockedAt, this.evidence});
  factory Achievement.fromRow(Map<String, Object?> r) => Achievement(key: r['key'] as String, unlockedAt: r['unlocked_at'] as int, evidence: r['evidence'] == null ? null : (jsonDecode(r['evidence'] as String) as Map).cast<String, Object?>());
  Map<String, Object?> toJson() => {'key': key, 'unlocked_at': unlockedAt, 'evidence': evidence};
  AchievementDef? get def => achievementDefs.where((d) => d.key == key).firstOrNull;
}

Map<String, Object?>? _milestoneCheck(AchievementContext c, int pct) {
  for (final p in c.goals) {
    if (p.goal.kind != GoalKind.wish) continue;
    if (p.targetMinor > 0 && p.savedMinor * 100 >= p.targetMinor * pct && p.savedMinor > 0) return {'goal': p.goal.name, 'saved': p.savedMinor, 'target': p.targetMinor};
  }
  return null;
}

Map<String, Object?>? _emergencyCheck(AchievementContext c, double months) {
  // 成就解锁了就不收回：月支出基线得是真数（历史整月均值 / 手填），第一个月按收入、按几天外推的估算太抖，不拿来发成就
  if (c.metrics.spendBasis != SpendBasis.history && c.metrics.spendBasis != SpendBasis.manual) return null;
  final r = c.metrics.runwayMonths;
  if (r != null && r >= months) return {'runway_months': double.parse(r.toStringAsFixed(1)), 'liquid': c.metrics.liquidMinor, 'monthly_spend': c.metrics.monthlySpendAvgMinor};
  return null;
}

Map<String, Object?>? _savingsCheck(AchievementContext c, double rate) {
  // 只看已经过完的月份：当月还没花完，储蓄率虚高
  final t = DateTime.parse('${c.today}T00:00:00Z');
  final m = DateTime.utc(t.year, t.month - 1, 1);
  final last = DateTime.utc(m.year, m.month + 1, 0);
  // 那个月得是整月都在记账（最早一笔记录在月初之前或当天）：月中才开始记的，只记了一部分支出，储蓄率虚高
  final first = c.ledger.firstOccurredAtMs();
  if (first == null || first > m.add(const Duration(days: 1)).millisecondsSinceEpoch) return null;
  var income = 0;
  var expense = 0;
  for (final tx in c.ledger.listTransactions(from: m.subtract(const Duration(days: 1)), to: last.add(const Duration(days: 2)), limit: 1 << 30)) {
    final d = tx.occurredAt.localDate;
    if (d.compareTo(_fmt(m)) < 0 || d.compareTo(_fmt(last)) > 0) continue;
    if (tx.type == TransactionType.income) income += tx.amountMinor;
    if (tx.type == TransactionType.expense) expense += tx.amountMinor;
    if (tx.type == TransactionType.refund) expense -= tx.amountMinor;
  }
  if (income <= 0) return null;
  final r = (income - expense) / income;
  return r >= rate ? {'month': '${m.year}-${m.month.toString().padLeft(2, '0')}', 'rate': double.parse(r.toStringAsFixed(2))} : null;
}

Map<String, Object?>? _lineCheck(AchievementContext c, IncomeLine line) {
  for (final tx in c.ledger.listTransactions(type: TransactionType.income, limit: 1 << 30)) {
    if (Wealth.lineOf(tx.categoryId, c.ledger.profile.incomeLines) == line) return {'transaction': tx.id, 'amount': tx.amountMinor, 'date': tx.occurredAt.localDate};
  }
  return null;
}

String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 全部成就定义。key 一旦发出去就不改。
final achievementDefs = <AchievementDef>[
  AchievementDef(key: 'goal.first', group: 'goal', title: '第一个目标', description: '建了第一个目标', check: (c) => c.goals.isEmpty ? null : {'goal': c.goals.first.goal.name}),
  AchievementDef(key: 'goal.p10', group: 'goal', title: '起跑', description: '某个心愿攒到 10%', check: (c) => _milestoneCheck(c, 10)),
  AchievementDef(key: 'goal.p25', group: 'goal', title: '四分之一', description: '某个心愿攒到 25%', check: (c) => _milestoneCheck(c, 25)),
  AchievementDef(key: 'goal.p50', group: 'goal', title: '过半', description: '某个心愿攒到 50%', check: (c) => _milestoneCheck(c, 50)),
  AchievementDef(key: 'goal.p75', group: 'goal', title: '看得见了', description: '某个心愿攒到 75%', check: (c) => _milestoneCheck(c, 75)),
  AchievementDef(key: 'goal.reached', group: 'goal', title: '攒够了', description: '某个目标攒到 100%', check: (c) => c.goals.where((p) => p.reached && p.goal.kind == GoalKind.wish).map((p) => {'goal': p.goal.name}).firstOrNull),
  AchievementDef(key: 'goal.redeemed', group: 'goal', title: '兑现', description: '真的把攒的钱花在了目标上', check: (c) => c.ledger.goals.list(activeOnly: false).where((g) => g.status == GoalStatus.done && g.kind == GoalKind.wish).map((g) => {'goal': g.name}).firstOrNull),
  AchievementDef(key: 'emergency.1', group: 'saving', title: '一个月', description: '流动资产够花 1 个月', check: (c) => _emergencyCheck(c, 1)),
  AchievementDef(key: 'emergency.3', group: 'saving', title: '三个月', description: '流动资产够花 3 个月（应急金及格线）', check: (c) => _emergencyCheck(c, 3)),
  AchievementDef(key: 'emergency.6', group: 'saving', title: '半年', description: '流动资产够花 6 个月', check: (c) => _emergencyCheck(c, 6)),
  AchievementDef(key: 'savings.20', group: 'saving', title: '存下两成', description: '上个月储蓄率 ≥ 20%', check: (c) => _savingsCheck(c, 0.2)),
  AchievementDef(key: 'savings.30', group: 'saving', title: '存下三成', description: '上个月储蓄率 ≥ 30%', check: (c) => _savingsCheck(c, 0.3)),
  AchievementDef(key: 'savings.50', group: 'saving', title: '存下一半', description: '上个月储蓄率 ≥ 50%', check: (c) => _savingsCheck(c, 0.5)),
  AchievementDef(key: 'task.first', group: 'habit', title: '第一个任务', description: '完成了第一个周任务', check: (c) => c.settledTasks.where((t) => t.result == TaskResult.done).map((t) => {'task': t.title, 'week': t.week}).firstOrNull),
  AchievementDef(
    key: 'task.streak4',
    group: 'habit',
    title: '四周连胜',
    description: '连续 4 周每个任务都完成',
    check: (c) {
      final byWeek = <String, bool>{};
      for (final t in c.settledTasks) {
        byWeek[t.week] = (byWeek[t.week] ?? true) && t.result == TaskResult.done;
      }
      final weeks = byWeek.keys.toList()..sort((a, b) => b.compareTo(a));
      var streak = 0;
      String? prev;
      for (final w in weeks) {
        if (!byWeek[w]!) break;
        if (prev != null && TaskStore.previousWeek(prev) != w) break;
        streak++;
        prev = w;
        if (streak >= 4) return {'weeks': weeks.take(4).toList()};
      }
      return null;
    },
  ),
  AchievementDef(key: 'income.side', group: 'income', title: '副本收入', description: '第一笔兼职 / 外快收入', check: (c) => _lineCheck(c, IncomeLine.side)),
  AchievementDef(key: 'income.passive', group: 'income', title: '挂机收入', description: '第一笔利息 / 分红 / 理财收益', check: (c) => _lineCheck(c, IncomeLine.passive)),
  AchievementDef(
    key: 'debt.clear',
    group: 'debt',
    title: '清零',
    description: '某个「还清」目标归零',
    check: (c) => c.goals.where((p) => p.goal.kind == GoalKind.payoff && p.reached).map((p) => {'goal': p.goal.name}).firstOrNull,
  ),
  AchievementDef(key: 'record.30', group: 'record', title: '一个月', description: '连续 30 天有记录', check: (c) => _streak(c, 30)),
  AchievementDef(key: 'record.100', group: 'record', title: '一百天', description: '连续 100 天有记录', check: (c) => _streak(c, 100)),
  AchievementDef(key: 'record.1000', group: 'record', title: '一千笔', description: '账本满 1000 笔', check: (c) => c.ledger.countTransactions() >= 1000 ? {'count': c.ledger.countTransactions()} : null),
  AchievementDef(key: 'support.yujian', group: 'record', title: '支持者', description: '给余见付了一块钱', check: (c) => c.ledger.profile.supporterSince == null ? null : {'since': c.ledger.profile.supporterSince}),
];

Map<String, Object?>? _streak(AchievementContext c, int days) {
  final t = DateTime.parse('${c.today}T00:00:00Z');
  final from = t.subtract(Duration(days: days + 1));
  final have = <String>{};
  for (final tx in c.ledger.listTransactions(from: from, limit: 1 << 30)) {
    have.add(tx.occurredAt.localDate);
  }
  var n = 0;
  for (var d = t; n < days; d = d.subtract(const Duration(days: 1))) {
    if (!have.contains(_fmt(d))) {
      // 今天还没记不算断
      if (n == 0 && _fmt(d) == c.today) continue;
      return null;
    }
    n++;
  }
  return {'days': days, 'until': c.today};
}

class AchievementStore {
  final Ledger ledger;
  final LedgerDatabase _db;
  final int Function() _nowMs;
  final ChangeLog? _changes;
  AchievementStore(this.ledger, this._db, this._nowMs, [this._changes]);

  List<Achievement> list() => _db.select('SELECT * FROM achievements ORDER BY unlocked_at DESC').map(Achievement.fromRow).toList();
  bool has(String key) => _db.select('SELECT 1 FROM achievements WHERE key = ?', [key]).isNotEmpty;

  /// 跑一遍所有定义，把新达成的记下来；返回本次新解锁的。
  List<Achievement> check(AchievementContext ctx) {
    final out = <Achievement>[];
    for (final d in achievementDefs) {
      if (has(d.key)) continue;
      Map<String, Object?>? ev;
      try {
        ev = d.check(ctx);
      } catch (_) {
        continue; // 单个定义算炸了不影响别的
      }
      if (ev == null) continue;
      final ts = _nowMs();
      _db.execute('INSERT OR IGNORE INTO achievements(key, unlocked_at, evidence) VALUES (?,?,?)', [d.key, ts, jsonEncode(ev)]);
      final a = Achievement(key: d.key, unlockedAt: ts, evidence: ev);
      ledger.auditGoal('achievement.unlock', d.key, after: a.toJson());
      _changes?.record('achievement', d.key, a.toJson());
      out.add(a);
    }
    return out;
  }

  /// 同步：同一成就两端都解锁时取最早的时间。
  void upsertRaw(Map<String, Object?> p) {
    final key = p['key'] as String;
    final at = (p['unlocked_at'] as num?)?.toInt() ?? _nowMs();
    final r = _db.select('SELECT unlocked_at FROM achievements WHERE key = ?', [key]);
    if (r.isNotEmpty && (r.first['unlocked_at'] as int) <= at) return;
    _db.execute('INSERT OR REPLACE INTO achievements(key, unlocked_at, evidence) VALUES (?,?,?)', [key, at, p['evidence'] == null ? null : jsonEncode(p['evidence'])]);
  }

  void deleteRaw(String key) => _db.execute('DELETE FROM achievements WHERE key = ?', [key]);
}
