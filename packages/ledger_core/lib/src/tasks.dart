import 'dart:convert';

import 'changes.dart';
import 'db/database.dart';
import 'errors.dart';
import 'ids.dart';
import 'ledger.dart';
import 'models/enums.dart';
import 'models/transaction.dart';

/// 周任务的判定器种类：
/// - categoryCap：某分类本周支出 ≤ cap
/// - countCap：商户 / 描述含关键词的支出本周 ≤ max 次
/// - noSpendDays：本周至少 N 个「无消费日」（当天没有非固定支出；周期账单生成的不算破功）
/// - streakDays：本周每天都有记录
/// - deposit：本周往某目标至少存 N
enum TaskKind { categoryCap, countCap, noSpendDays, streakDays, deposit }

enum TaskResult { pending, done, missed }

class WeeklyTask {
  final String id;
  final String week; // 那一周周一 yyyy-MM-dd
  final TaskKind kind;
  final Map<String, Object?> params;
  final String title;
  final TaskResult result;
  final String? rewardGoalId;
  final int rewardMinor;
  final String source; // template | model | user
  final Map<String, Object?>? evidence; // 结算时的数字
  final int? settledAt;
  final int createdAt;

  const WeeklyTask({
    required this.id,
    required this.week,
    required this.kind,
    required this.params,
    required this.title,
    required this.result,
    this.rewardGoalId,
    this.rewardMinor = 0,
    required this.source,
    this.evidence,
    this.settledAt,
    required this.createdAt,
  });

  factory WeeklyTask.fromRow(Map<String, Object?> r) => WeeklyTask(
        id: r['id'] as String,
        week: r['week'] as String,
        kind: TaskKind.values.byName(r['kind'] as String), // 未知种类在 list() 里就筛掉了
        params: (jsonDecode(r['params'] as String) as Map).cast<String, Object?>(),
        title: r['title'] as String,
        result: TaskResult.values.asNameMap()[r['result']] ?? TaskResult.pending,
        rewardGoalId: r['reward_goal_id'] as String?,
        rewardMinor: r['reward_minor'] as int,
        source: r['source'] as String,
        evidence: r['evidence'] == null ? null : (jsonDecode(r['evidence'] as String) as Map).cast<String, Object?>(),
        settledAt: r['settled_at'] as int?,
        createdAt: r['created_at'] as int,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'week': week,
        'kind': kind.name,
        'params': params,
        'title': title,
        'result': result.name,
        'reward_goal_id': rewardGoalId,
        'reward_minor': rewardMinor,
        'source': source,
        'evidence': evidence,
        'settled_at': settledAt,
      };
}

/// 任务的实时进度（不落库）。
class TaskProgress {
  final WeeklyTask task;
  final int current; // 当前计数 / 金额
  final int limit; // 上限或目标
  final bool onTrack; // 到现在为止还没破
  final bool achieved; // 已经达成（对「至少」类任务）
  final String detail; // 一句人话
  const TaskProgress({required this.task, required this.current, required this.limit, required this.onTrack, required this.achieved, required this.detail});
}

/// 模板任务（不需要模型）。
class TaskTemplate {
  final TaskKind kind;
  final Map<String, Object?> params;
  final String title;
  const TaskTemplate({required this.kind, required this.params, required this.title});
}

class TaskStore {
  final Ledger ledger;
  final LedgerDatabase _db;
  final int Function() _nowMs;
  final ChangeLog? _changes;
  TaskStore(this.ledger, this._db, this._nowMs, [this._changes]);

  /// 某天所在周的周一。
  static String weekOf(String date) {
    final d = _parse(date);
    return _fmt(d.subtract(Duration(days: d.weekday - 1)));
  }

  static String previousWeek(String weekMonday) => _fmt(_parse(weekMonday).subtract(const Duration(days: 7)));

  WeeklyTask create({required String week, required TaskKind kind, required Map<String, Object?> params, required String title, String? rewardGoalId, int rewardMinor = 0, String source = 'template'}) {
    if (title.trim().isEmpty) throw ValidationException('title', 'required');
    final id = Ulid.next();
    _db.execute(
      "INSERT INTO tasks(id,week,kind,params,title,result,reward_goal_id,reward_minor,source,evidence,settled_at,created_at,updated_at) VALUES (?,?,?,?,?,'pending',?,?,?,NULL,NULL,?,?)",
      [id, week, kind.name, jsonEncode(params), title.trim(), rewardGoalId, rewardMinor, source, _nowMs(), _nowMs()],
    );
    final t = get(id);
    ledger.auditGoal('task.create', id, after: t.toJson());
    _changes?.record('task', id, t.toJson());
    return t;
  }

  WeeklyTask get(String id) {
    final r = _db.select('SELECT * FROM tasks WHERE id = ?', [id]);
    if (r.isEmpty) throw NotFoundException('task', id);
    return WeeklyTask.fromRow(r.first);
  }

  List<WeeklyTask> list({String? week, int limit = 200}) => _db
      .select('SELECT * FROM tasks ${week == null ? '' : 'WHERE week = ?'} ORDER BY week DESC, created_at LIMIT ?', [if (week != null) week, limit])
      .where((r) => TaskKind.values.asNameMap().containsKey(r['kind'])) // 新版本同步来的任务种类老版本判定不了：不显示，也不结算
      .map(WeeklyTask.fromRow)
      .toList();

  void delete(String id) {
    get(id);
    _db.execute('DELETE FROM tasks WHERE id = ?', [id]);
    _changes?.record('task', id, null, deleted: true);
  }

  void upsertRaw(Map<String, Object?> p) => _db.execute(
        'INSERT OR REPLACE INTO tasks(id,week,kind,params,title,result,reward_goal_id,reward_minor,source,evidence,settled_at,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,COALESCE((SELECT created_at FROM tasks WHERE id = ?),?),?)',
        [p['id'], p['week'], p['kind'], jsonEncode(p['params'] ?? const {}), p['title'], p['result'] ?? 'pending', p['reward_goal_id'], p['reward_minor'] ?? 0, p['source'] ?? 'template', p['evidence'] == null ? null : jsonEncode(p['evidence']), p['settled_at'], p['id'], _nowMs(), _nowMs()],
      );
  void deleteRaw(String id) => _db.execute('DELETE FROM tasks WHERE id = ?', [id]);

  // -------------------------------------------------------------- evaluate

  /// 实时进度；[today] 用来判断「到现在为止」。
  TaskProgress progress(WeeklyTask t, {required String today}) {
    final monday = _parse(t.week);
    final sunday = monday.add(const Duration(days: 6));
    final end = _parse(today).isBefore(sunday) ? _parse(today) : sunday;
    final txs = _range(t.week, _fmt(end));
    switch (t.kind) {
      case TaskKind.categoryCap:
        final cat = t.params['category_id'] as String?;
        final cap = (t.params['cap_minor'] as num?)?.toInt() ?? 0;
        final cats = _withChildren(cat);
        var spent = 0;
        for (final x in txs) {
          if (x.type == TransactionType.expense && (cat == null || cats.contains(x.categoryId))) spent += x.amountMinor;
          if (x.type == TransactionType.refund && (cat == null || cats.contains(x.categoryId))) spent -= x.amountMinor;
        }
        return TaskProgress(task: t, current: spent, limit: cap, onTrack: spent <= cap, achieved: false, detail: '已用 ${_money(spent)} / ${_money(cap)}');
      case TaskKind.countCap:
        final kws = ((t.params['keywords'] as List?) ?? const []).cast<String>().map((k) => k.toLowerCase()).toList();
        final max = (t.params['max'] as num?)?.toInt() ?? 0;
        var n = 0;
        for (final x in txs) {
          if (x.type != TransactionType.expense) continue;
          final hay = '${x.merchant ?? ''} ${x.description ?? ''}'.toLowerCase();
          if (kws.any(hay.contains)) n++;
        }
        return TaskProgress(task: t, current: n, limit: max, onTrack: n <= max, achieved: false, detail: '$n / $max 次');
      case TaskKind.noSpendDays:
        final min = (t.params['min_days'] as num?)?.toInt() ?? 1;
        final days = <String>{};
        for (var d = monday; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
          days.add(_fmt(d));
        }
        for (final x in txs) {
          // 周期账单（房租、订阅）自动扣的不算破功：认 recurring_id，老数据没有这个字段的按来源认
          if (x.type == TransactionType.expense && x.recurringId == null && x.source != Source.recurring) days.remove(x.occurredAt.localDate);
        }
        final remainingDays = sunday.difference(end).inDays;
        return TaskProgress(task: t, current: days.length, limit: min, onTrack: days.length + remainingDays >= min, achieved: days.length >= min, detail: '${days.length} / $min 天没花钱');
      case TaskKind.streakDays:
        // 只认用户自己记的：周期账单、自动定存这类自动生成的不算「有记录」
        final days = <String>{for (final x in txs) if (x.source != Source.recurring) x.occurredAt.localDate};
        var have = 0;
        for (var d = monday; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
          if (days.contains(_fmt(d))) have++;
        }
        final total = end.difference(monday).inDays + 1;
        return TaskProgress(task: t, current: have, limit: 7, onTrack: have == total, achieved: have == 7, detail: '$have / 7 天有记录');
      case TaskKind.deposit:
        final gid = t.params['goal_id'] as String?;
        final min = (t.params['min_minor'] as num?)?.toInt() ?? 0;
        final g = gid == null ? null : ledger.goals.find(gid);
        var sum = 0;
        if (g?.vaultAccountId != null) {
          for (final x in txs) {
            if (x.type == TransactionType.transfer && x.toAccountId == g!.vaultAccountId) sum += x.amountMinor;
          }
        }
        return TaskProgress(task: t, current: sum, limit: min, onTrack: true, achieved: sum >= min, detail: '已存 ${_money(sum)} / ${_money(min)}');
    }
  }

  /// 结算某一周（周日过后调用；延后到下次打开也算）。已结算的跳过。返回结算了的任务。
  List<WeeklyTask> settle(String week, {required String today}) {
    if (today.compareTo(_fmt(_parse(week).add(const Duration(days: 7)))) < 0) return const []; // 这周还没过完
    final out = <WeeklyTask>[];
    for (final t in list(week: week)) {
      if (t.result != TaskResult.pending) continue;
      final p = progress(t, today: _fmt(_parse(week).add(const Duration(days: 6))));
      final done = switch (t.kind) {
        TaskKind.categoryCap || TaskKind.countCap => p.onTrack,
        _ => p.achieved,
      };
      final evidence = {'current': p.current, 'limit': p.limit, 'detail': p.detail};
      _db.execute('UPDATE tasks SET result = ?, evidence = ?, settled_at = ?, updated_at = ? WHERE id = ?', [done ? 'done' : 'missed', jsonEncode(evidence), _nowMs(), _nowMs(), t.id]);
      final after = get(t.id);
      ledger.auditGoal('task.settle', t.id, after: after.toJson());
      _changes?.record('task', t.id, after.toJson());
      out.add(after);
    }
    return out;
  }

  /// 内置模板：按账本情况挑出 3～5 个合适的（不需要模型）。
  List<TaskTemplate> templates({required String today}) {
    final out = <TaskTemplate>[];
    final lastWeek = previousWeek(weekOf(today));
    final txs = _range(lastWeek, _fmt(_parse(lastWeek).add(const Duration(days: 6))));
    // 上周花得最多的分类 → 本周少 15%
    final byCat = <String, int>{};
    for (final x in txs) {
      // 和进度同一个口径：退款冲减（上周买了又退的不该把本周上限抬高）
      if (x.type == TransactionType.expense && x.categoryId != null) byCat[x.categoryId!] = (byCat[x.categoryId!] ?? 0) + x.amountMinor;
      if (x.type == TransactionType.refund && x.categoryId != null) byCat[x.categoryId!] = (byCat[x.categoryId!] ?? 0) - x.amountMinor;
    }
    final top = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in top.take(2)) {
      final c = ledger.category(e.key);
      if (c == null || e.value < 5000) continue;
      final cap = (e.value * 0.85 / 100).round() * 100;
      out.add(TaskTemplate(kind: TaskKind.categoryCap, params: {'category_id': e.key, 'cap_minor': cap}, title: '本周${c.name}不超过 ${_money(cap)}'));
    }
    // 外卖次数
    var takeout = 0;
    for (final x in txs) {
      final hay = '${x.merchant ?? ''} ${x.description ?? ''}';
      if (x.type == TransactionType.expense && RegExp('美团|饿了么|外卖').hasMatch(hay)) takeout++;
    }
    if (takeout >= 3) {
      out.add(TaskTemplate(kind: TaskKind.countCap, params: {'keywords': ['美团', '饿了么', '外卖'], 'max': (takeout - 1).clamp(1, 99)}, title: '本周外卖不超过 ${(takeout - 1).clamp(1, 99)} 次'));
    }
    out.add(const TaskTemplate(kind: TaskKind.noSpendDays, params: {'min_days': 2}, title: '本周至少 2 个无消费日'));
    // 往第一个有锁仓的目标存一笔
    for (final g in ledger.goals.list()) {
      if (g.vaultAccountId == null) continue;
      final p = ledger.goals.progress(g, today: today);
      if (p.reached) continue;
      final amt = (p.remainingMinor / 10).clamp(2000, 50000).round() ~/ 100 * 100;
      out.add(TaskTemplate(kind: TaskKind.deposit, params: {'goal_id': g.id, 'min_minor': amt}, title: '本周往「${g.name}」存 ${_money(amt)}'));
      break;
    }
    return out;
  }

  Set<String> _withChildren(String? cat) {
    if (cat == null) return const {};
    final cats = {cat};
    final all = ledger.listCategories();
    var grew = true;
    while (grew) {
      grew = false;
      for (final c in all) {
        if (c.parentId != null && cats.contains(c.parentId) && cats.add(c.id)) grew = true;
      }
    }
    return cats;
  }

  List<Transaction> _range(String from, String to) {
    final f = _parse(from).subtract(const Duration(days: 1));
    final tt = _parse(to).add(const Duration(days: 2));
    return [
      for (final tx in ledger.listTransactions(from: f, to: tt, limit: 1 << 30))
        if (tx.occurredAt.localDate.compareTo(from) >= 0 && tx.occurredAt.localDate.compareTo(to) <= 0) tx,
    ];
  }

  static String _money(int minor) => minor % 100 == 0 ? '¥${minor ~/ 100}' : '¥${(minor / 100).toStringAsFixed(2)}';

  static DateTime _parse(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
