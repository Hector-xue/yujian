import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:persona/persona.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../widgets/fmt.dart';

/// 对话里识别出的「攒 X 买 Y」：对话页渲染成一张「建这个目标」卡。
class GoalSuggestion {
  final String name;
  final int amountMinor;
  const GoalSuggestion(this.name, this.amountMinor);
}

/// 财富游戏层：把账本里的真数（可花的 / 等级 / 目标进度 / 任务 / 成就）算好缓存，
/// 处理目标的存入 / 兑现 / 释放，周任务的生成与结算，三个仪式，以及要送进对话页的人格化消息。
/// 数字全部来自 Ledger Core；这里不写任何账本事实，写入照旧走 propose → commit。
class GameLayer extends ChangeNotifier {
  final AppState app;
  GameLayer(this.app);

  Ledger get ledger => app.ledger;

  WealthMetrics? _metrics;
  List<GoalProgress> _goals = const [];
  List<WeeklyTask> _weekTasks = const [];
  Map<String, TaskProgress> _taskProgress = const {};
  List<Achievement> _achievements = const [];
  List<TaskTemplate> candidates = const [];
  bool candidatesFromModel = false;

  /// 本周被用户划掉的候选（按 [candidateKey] 记），落 SharedPreferences；换周自动清空。
  /// 候选本身不落库（每次打开按上周账本现算），不记这份的话划掉的下次打开又冒出来。
  Set<String> _dismissedCandidates = const {};
  static const _dismissedKey = 'task_candidates_dismissed';

  /// 候选的身份：类型 + 参数（键排序后的 JSON）。同一周里同一个模板算出来的参数是一样的，模型提的也按内容认。
  static String candidateKey(TaskTemplate t) {
    final keys = t.params.keys.toList()..sort();
    return '${t.kind.name}|${jsonEncode({for (final k in keys) k: t.params[k]})}';
  }

  /// 缓存按需重算：账本变了只打个脏标记，谁先读谁触发这一次计算（一次变化只算一次，不在每次 build 里算）。
  WealthMetrics? get metrics {
    _ensure();
    return _metrics;
  }

  List<GoalProgress> get goals {
    _ensure();
    return _goals;
  }

  List<WeeklyTask> get weekTasks {
    _ensure();
    return _weekTasks;
  }

  Map<String, TaskProgress> get taskProgress {
    _ensure();
    return _taskProgress;
  }

  List<Achievement> get achievements {
    _ensure();
    return _achievements;
  }

  /// 要在对话页里由助手说出来的话（成就 / 升级 / 任务结算 / 月度复盘），对话页取走后清空。
  final List<({String text, String? sticker, String? meta})> pendingMessages = [];
  GoalSuggestion? _suggestion;

  bool _dirty = true;
  bool _scheduled = false;

  String get _today => todayLocal();
  String get thisWeek => TaskStore.weekOf(_today);

  // ---------------------------------------------------------------- 开关

  /// 表达层总开关：可花的 / 今天还能花 / 等级 / 代价行 / 仪式 / 成就。目标本身不受它管。
  bool get enabled => ledger.profile.getBool(ProfileStore.keyGameLayer, fallback: true);
  Future<void> setEnabled(bool v) async {
    ledger.profile.setBool(ProfileStore.keyGameLayer, v);
    notifyListeners();
    app.touch();
  }

  bool get costLine => enabled && ledger.profile.getBool(ProfileStore.keyCostLine, fallback: true);
  Future<void> setCostLine(bool v) async {
    ledger.profile.setBool(ProfileStore.keyCostLine, v);
    notifyListeners();
  }

  Map<String, bool> get rituals => ledger.profile.rituals;
  Future<void> setRitual(String key, bool v) async {
    ledger.profile.rituals = {...rituals, key: v};
    notifyListeners();
  }

  // ---------------------------------------------------------------- 重算

  /// 账本一变就打脏标记；下一轮微任务里算一次并通知（不用 Timer：测试里不会悬挂，真机上也不会攒出多次计算）。
  void markDirty() {
    _dirty = true;
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_dirty) return;
      _ensure();
      notifyListeners();
    });
  }

  /// 立刻算一遍（启动 / 仪式跑完后）。
  Future<void> recompute() async {
    _dirty = true;
    _ensure();
    notifyListeners();
  }

  void _ensure() {
    if (!_dirty) return;
    _dirty = false;
    try {
      final today = _today;
      final m = Wealth(ledger).compute(today: today);
      _metrics = m;
      _goals = [for (final g in ledger.goals.list()) ledger.goals.progress(g, today: today, liquidMinor: m.liquidMinor, netWorthMinor: m.netWorthMinor)];
      _weekTasks = ledger.tasks.list(week: thisWeek);
      _taskProgress = {for (final t in _weekTasks) t.id: ledger.tasks.progress(t, today: today)};
      _achievements = ledger.achievements.list();
      unawaited(_checkAchievementsAndLevel(m));
    } catch (_) {
      // 指标算不出来不能拖垮页面
    }
  }

  Future<void> _checkAchievementsAndLevel(WealthMetrics m) async {
    await null; // 让出这一轮：_ensure 可能在 build 里被调，这里的 notifyListeners 不能同步发生
    final settled = ledger.tasks.list(limit: 200).where((t) => t.result != TaskResult.pending).toList();
    final fresh = ledger.achievements.check(AchievementContext(ledger: ledger, metrics: m, today: _today, goals: _goals, settledTasks: settled));
    if (fresh.isNotEmpty) _achievements = ledger.achievements.list();
    if (!enabled) return;
    var changed = fresh.isNotEmpty;
    for (final a in fresh) {
      final d = a.def;
      if (d == null) continue;
      if (a.key.startsWith('goal.p')) {
        pendingMessages.add((text: app.replier.template(PersonaEvent.goalMilestone, n: int.parse(a.key.substring(6)), label: '${a.evidence?['goal'] ?? ''}'), sticker: null, meta: '成就 · ${d.title}'));
      } else if (a.key == 'goal.reached') {
        pendingMessages.add((text: app.replier.template(PersonaEvent.goalReached, label: '${a.evidence?['goal'] ?? ''}'), sticker: '🎉', meta: '成就 · ${d.title}'));
      } else if (a.key == 'support.yujian') {
        pendingMessages.add((text: '收到你的一块钱了。谢谢，那条提醒已经永久关掉。', sticker: '🙏', meta: '成就 · ${d.title}'));
      } else {
        pendingMessages.add((text: '${d.title}：${d.description}。', sticker: null, meta: '成就解锁'));
      }
    }
    // 升级：和上次记的等级比
    final lvl = m.level;
    if (lvl != null) {
      try {
        final p = await SharedPreferences.getInstance();
        final last = p.getInt('wealth_level');
        // 只在超过「喊过的最高等级」时才喊升级：生存月数在临界点来回抖（记一笔掉下去、进一笔工资又上来），不能每次都喊
        final announced = p.getInt('wealth_level_max') ?? last;
        if (announced != null && lvl.index > announced) {
          // 净资产为负时称号是负翁那套，升级喊的名字跟首页角标一致
          pendingMessages.add((text: app.replier.template(PersonaEvent.levelUp, label: m.title ?? lvl.title), sticker: '⬆️', meta: '等级「${lvl.name}」· 生存月数 ${m.runwayMonths!.toStringAsFixed(1)} 个月'));
          changed = true;
        }
        if (last != lvl.index) await p.setInt('wealth_level', lvl.index);
        if (announced == null || lvl.index > announced) await p.setInt('wealth_level_max', lvl.index);
      } catch (_) {}
    }
    if (changed) notifyListeners();
  }

  List<({String text, String? sticker, String? meta})> takeMessages() {
    final out = List.of(pendingMessages);
    pendingMessages.clear();
    return out;
  }

  // ---------------------------------------------------------------- 目标

  GoalProgress? progressOf(String goalId) => goals.where((p) => p.goal.id == goalId).firstOrNull;

  Future<Goal> createGoal({required GoalKind kind, required String name, required int targetMinor, String? emoji, String? deadline, String? vaultAccountId, String? linkedAccountId, List<GoalRule> rules = const [], bool withVault = true}) async {
    final g = ledger.goals.create(kind: kind, name: name, targetMinor: targetMinor, emoji: emoji, deadline: deadline, vaultAccountId: vaultAccountId, linkedAccountId: linkedAccountId, rules: rules, withVault: withVault);
    if (enabled) pendingMessages.add((text: app.replier.template(PersonaEvent.goalCreated, label: g.name), sticker: null, meta: null));
    app.touch();
    return g;
  }

  Future<Goal> updateGoal(String id, {String? name, String? emoji, int? targetMinor, String? deadline, bool clearDeadline = false, List<GoalRule>? rules}) async {
    final g = ledger.goals.update(id, name: name, emoji: emoji, targetMinor: targetMinor, deadline: deadline, clearDeadline: clearDeadline, rules: rules);
    app.touch();
    return g;
  }

  Future<void> reorderGoals(List<String> ids) async {
    ledger.goals.reorder(ids);
    app.touch();
  }

  String _defaultFrom(Goal g) {
    for (final r in g.rules) {
      if (r.fromAccountId != null && ledger.account(r.fromAccountId!) != null) return r.fromAccountId!;
    }
    final sal = ledger.profile.salaryAccountId;
    if (sal != null && ledger.account(sal) != null) return sal;
    return app.defaultAccountId ?? (throw StateError('还没有账户'));
  }

  /// 存入。虚拟锁仓：只是标记，直接记账；真锁仓：进收件箱，用户去银行 App 真转了再确认。
  /// 返回 null = 已记账；返回草稿 = 等确认。
  Future<Draft?> deposit(Goal g, int amountMinor, {String? fromAccountId, String? fingerprint, String? note, Source source = Source.manual}) async {
    final from = fromAccountId ?? _defaultFrom(g);
    final payload = ledger.goals.depositPayload(g, amountMinor, fromAccountId: from, note: note);
    // 虚拟锁仓：起草 + 确认同一个事务，确认失败不留草稿
    final d = ledger.database.transaction(() {
      final d = ledger.propose([DraftInput(payload: payload, eventFingerprint: fingerprint, fingerprintIsExact: fingerprint != null)], source: source, actor: Actor.user, interpreter: 'goal').firstOrNull;
      if (d != null && g.isVirtualVault) ledger.commit(d.id);
      return d;
    });
    if (d == null) return null; // 指纹重复：这期已经存过
    if (g.isVirtualVault) {
      if (enabled) pendingMessages.add((text: app.replier.template(PersonaEvent.depositMade, n: amountMinor ~/ 100, label: g.name), sticker: null, meta: null));
      app.touch();
      return null;
    }
    app.touch();
    return d;
  }

  /// 兑现：从锁仓记一笔支出（可多笔）。
  Future<Transaction> redeem(Goal g, int amountMinor, {required String categoryId, String? merchant, String? description}) async {
    final t = ledger.database.transaction(() {
      final d = ledger.propose([DraftInput(payload: ledger.goals.redeemPayload(g, amountMinor, categoryId: categoryId, merchant: merchant, description: description))], source: Source.manual, actor: Actor.user, interpreter: 'goal').single;
      return ledger.commit(d.id);
    });
    app.touch();
    return t;
  }

  /// 完成（兑现结束）：剩余释放回来源，状态 done。
  Future<void> complete(Goal g) async {
    await release(g, silent: true);
    ledger.goals.update(g.id, status: GoalStatus.done);
    app.touch();
  }

  /// 归档：释放锁仓（虚拟的直接回；真实的只是不再算作锁定，钱本来就在那个账户里），状态 archived。
  Future<void> archive(Goal g) async {
    await release(g, silent: true);
    ledger.goals.update(g.id, status: GoalStatus.archived);
    app.touch();
  }

  /// 删目标：锁仓里的钱先释放回来源（虚拟锁仓），再连锁仓账户一起清（没记录真删、存过钱归档，见 Goals.remove）。
  Future<GoalRemoval> deleteGoal(Goal g) async {
    await release(g, silent: true);
    final r = ledger.goals.remove(g.id);
    app.touch();
    return r;
  }

  /// 释放锁仓余额回来源账户。真锁仓不动钱（钱在用户自己的账户里，只是解除「锁定」标记 = 把 vault 指向清掉）。
  Future<void> release(Goal g, {bool silent = false}) async {
    if (g.vaultAccountId == null) return;
    if (!g.isVirtualVault) return; // 真锁仓：钱就在那个账户里，无需转
    final backs = ledger.goals.releasePayloads(g, fallbackAccountId: _defaultFrom(g));
    // 多笔释放要么全成、要么全不成（不会只退回一半）
    ledger.database.transaction(() {
      for (final b in backs) {
        final d = ledger.propose([DraftInput(payload: b)], source: Source.manual, actor: Actor.user, interpreter: 'goal').single;
        ledger.commit(d.id);
      }
    });
    if (!silent) app.touch();
  }

  /// 收件箱代价行：这笔支出 = 某个目标晚几天 / 占多少；本周任务还剩多少。
  String? costLineFor(Map<String, Object?> payload) {
    if (!costLine) return null;
    if (payload['type'] != 'expense') return null;
    final amount = (payload['amount_minor'] as num?)?.toInt() ?? 0;
    if (amount <= 0) return null;
    final parts = <String>[];
    final g = goals.where((p) => p.goal.kind == GoalKind.wish && !p.reached && p.goal.hasVault).firstOrNull;
    if (g != null) {
      if (g.paceMinorPerDay != null && g.paceMinorPerDay! > 0) {
        final days = (amount / g.paceMinorPerDay!).round();
        if (days >= 1) parts.add('「${g.goal.name}」晚 $days 天');
      } else if (g.targetMinor > 0) {
        parts.add('「${g.goal.name}」的 ${(amount / g.targetMinor * 100).toStringAsFixed(1)}%');
      }
    }
    final cat = payload['category_id'] as String?;
    for (final t in weekTasks) {
      if (t.result != TaskResult.pending) continue;
      final p = taskProgress[t.id];
      if (p == null) continue;
      if (t.kind == TaskKind.categoryCap && (t.params['category_id'] == null || t.params['category_id'] == cat)) {
        final left = p.limit - p.current - amount;
        parts.add(left >= 0 ? '本周「${t.title}」还剩 ${fmtMoney(left, 'CNY')}' : '本周「${t.title}」会超 ${fmtMoney(-left, 'CNY')}');
      }
    }
    return parts.isEmpty ? null : '这笔 = ${parts.join(' · ')}';
  }

  // ---------------------------------------------------------------- 对话

  /// 「我想攒 5000 换手机」「存 3 万去日本」→ 目标建议。识别不出返回 null。
  GoalSuggestion? suggestFrom(String text) {
    final m = RegExp(r'(?:攒|存|省)\s*(?:到|够|个|下)?\s*([\d.]+)\s*(万|k|K|千|元|块)?\s*(?:元|块)?\s*(?:去|来|用来|为了|给)?\s*([^\s，。！？,.!?]{1,12})').firstMatch(text);
    if (m == null) return null;
    final unit = m.group(2);
    final num = double.tryParse(m.group(1)!);
    if (num == null || num <= 0) return null;
    final minor = (num * (unit == '万' ? 10000 : (unit == 'k' || unit == 'K' || unit == '千') ? 1000 : 1) * 100).round();
    var name = m.group(3)!.trim();
    name = name.replaceFirst(RegExp(r'^(一趟|一次|一部|一台|一辆|一套|个)'), '').trim();
    if (name.isEmpty || RegExp(r'^\d').hasMatch(name)) return null;
    // 太小的金额多半是记账不是目标（"存 28 到零钱"）
    if (minor < 50000) return null;
    _suggestion = GoalSuggestion(name, minor);
    return _suggestion;
  }

  GoalSuggestion? takeSuggestion() {
    final s = _suggestion;
    _suggestion = null;
    return s;
  }

  /// 对话里问目标进度：「日本游攒了多少」「换手机还差多少」「目标进度」。命中返回一句话。
  String? answerGoalQuery(String text) {
    if (goals.isEmpty) return null;
    if (!RegExp('攒了多少|还差多少|进度|攒到哪|还要多久|目标').hasMatch(text)) return null;
    final hit = goals.where((p) => text.contains(p.goal.name)).toList();
    final list = hit.isEmpty ? goals : hit;
    if (hit.isEmpty && !RegExp('目标|进度').hasMatch(text)) return null;
    return list.map(describe).join('\n');
  }

  String describe(GoalProgress p) {
    final g = p.goal;
    final b = StringBuffer('${g.emoji ?? ''}${g.name}：');
    switch (g.kind) {
      case GoalKind.wish:
      case GoalKind.milestone:
        b.write('${fmtMoney(p.savedMinor, g.currency)} / ${fmtMoney(p.targetMinor, g.currency)}（${(p.ratio * 100).toStringAsFixed(0)}%）');
        if (p.reached) {
          b.write('，攒够了');
        } else {
          b.write('，还差 ${fmtMoney(p.remainingMinor, g.currency)}');
          if (p.etaDays != null) b.write('，按最近的速度还要 ${_days(p.etaDays!)}');
          if (p.behindDays != null && p.behindDays! > 0) b.write('，比计划晚 ${p.behindDays} 天');
        }
      case GoalKind.emergency:
        final r = metrics?.runwayMonths;
        b.write(r == null ? '还没有足够的支出记录来算' : '现在够花 ${r.toStringAsFixed(1)} 个月，目标 ${fmtMoney(p.targetMinor, g.currency)}');
      case GoalKind.payoff:
        b.write('还欠 ${fmtMoney(p.remainingMinor, g.currency)}，已还 ${(p.ratio * 100).toStringAsFixed(0)}%');
    }
    return b.toString();
  }

  static String _days(int d) => d < 31 ? '$d 天' : d < 365 ? '${(d / 30).floor()} 个月零 ${d % 30} 天' : '${(d / 365).toStringAsFixed(1)} 年';

  // ---------------------------------------------------------------- 任务

  /// 启动 / 换周时：把过去的周结算掉（发人格消息 + 奖励存入），本周没有候选就生成。
  Future<void> ensureWeek() async {
    final today = _today;
    final week = thisWeek;
    // 结算所有还挂着的旧周
    final pendingWeeks = ledger.tasks.list(limit: 500).where((t) => t.result == TaskResult.pending && t.week.compareTo(week) < 0).map((t) => t.week).toSet().toList()..sort();
    for (final w in pendingWeeks) {
      final settled = ledger.tasks.settle(w, today: today);
      for (final t in settled) {
        if (enabled) {
          pendingMessages.add((text: app.replier.template(t.result == TaskResult.done ? PersonaEvent.taskDone : PersonaEvent.taskMissed, label: t.title), sticker: t.result == TaskResult.done ? '✅' : null, meta: '周任务结算 · ${t.evidence?['detail'] ?? ''}'));
        }
        if (t.result == TaskResult.done && t.rewardGoalId != null && t.rewardMinor > 0) {
          final g = ledger.goals.find(t.rewardGoalId!);
          if (g != null && g.hasVault) await deposit(g, t.rewardMinor, fingerprint: 'task:${t.id}:reward', note: '任务奖励「${t.title}」');
        }
      }
    }
    // 零头周结：补最近 4 个过完的周（隔几周没打开也不漏；指纹按周，已结过的自动跳过）
    var w = week;
    for (var i = 0; i < 4; i++) {
      w = TaskStore.previousWeek(w);
      for (final d in ledger.goals.roundupDue(weekMonday: w)) {
        await deposit(d.goal, d.amountMinor, fingerprint: d.fingerprint, note: d.note, source: Source.recurring);
      }
    }
    // 本周候选
    try {
      final p = await SharedPreferences.getInstance();
      _loadDismissed(p, week);
      if (p.getString('task_candidates_week') != week && ledger.tasks.list(week: week).isEmpty) {
        candidates = _withoutDismissed(ledger.tasks.templates(today: today));
        candidatesFromModel = false;
        await p.setString('task_candidates_week', week);
        if (rituals['weekly'] == true && enabled && candidates.isNotEmpty) {
          pendingMessages.add((text: '新的一周。本周任务候选有 ${candidates.length} 个，去「周任务」挑 1～3 个。', sticker: null, meta: '周一任务卡'));
        }
        unawaited(refineCandidatesWithModel());
      } else if (candidates.isEmpty && ledger.tasks.list(week: week).isEmpty) {
        candidates = _withoutDismissed(ledger.tasks.templates(today: today));
      }
    } catch (_) {}
    await recompute();
  }

  /// 有模型时让它在模板之外再提 2～3 个（只发账本速览 + 目标名，走 propose 逻辑：只进候选，用户勾选才生效）。
  Future<void> refineCandidatesWithModel() async {
    final p = app.taskProvider;
    if (p == null || !enabled) return;
    try {
      final brief = app.ledgerBrief();
      final goalLines = goals.map(describe).join('\n');
      final r = await p.complete(
        system: '你是记账 App 里的任务设计器。根据用户上周的账本速览和目标，提 2～3 个本周可执行、可由账本判定的小任务。只能用这几种：'
            'category_cap（某分类本周支出不超过 cap，元）、count_cap（商户关键词出现次数 ≤ max）、no_spend_days（至少 N 个无消费日）、deposit（往某目标存至少 N 元）。'
            '输出 JSON：{"tasks":[{"kind":"category_cap","title":"…","category_id":"…","cap":300}, {"kind":"count_cap","title":"…","keywords":["美团"],"max":3}, {"kind":"no_spend_days","title":"…","min_days":2}, {"kind":"deposit","title":"…","goal_id":"…","min":50}]}。'
            '不要说教，任务要具体、够得着。分类 id 只能用给定的。',
        user: '账本速览：\n$brief\n\n目标：\n$goalLines\n\n可用分类：${app.categories.where((c) => c.kind == CategoryKind.expense).map((c) => '${c.id}=${c.name}').join(', ')}\n可用目标 id：${goals.map((g) => '${g.goal.id}=${g.goal.name}').join(', ')}',
        jsonMode: true,
        timeout: const Duration(seconds: 20),
      );
      final j = jsonDecode(r.text) as Map;
      final extra = <TaskTemplate>[];
      for (final t in (j['tasks'] as List? ?? const []).cast<Map>()) {
        final title = '${t['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        switch (t['kind']) {
          case 'category_cap':
            final cat = t['category_id'] as String?;
            if (cat == null || ledger.category(cat) == null) continue;
            extra.add(TaskTemplate(kind: TaskKind.categoryCap, params: {'category_id': cat, 'cap_minor': ((t['cap'] as num?) ?? 0).round() * 100}, title: title));
          case 'count_cap':
            extra.add(TaskTemplate(kind: TaskKind.countCap, params: {'keywords': ((t['keywords'] as List?) ?? const []).map((k) => '$k').toList(), 'max': ((t['max'] as num?) ?? 1).toInt()}, title: title));
          case 'no_spend_days':
            extra.add(TaskTemplate(kind: TaskKind.noSpendDays, params: {'min_days': ((t['min_days'] as num?) ?? 1).toInt()}, title: title));
          case 'deposit':
            final gid = t['goal_id'] as String?;
            if (gid == null || ledger.goals.find(gid) == null) continue;
            extra.add(TaskTemplate(kind: TaskKind.deposit, params: {'goal_id': gid, 'min_minor': ((t['min'] as num?) ?? 0).round() * 100}, title: title));
        }
      }
      // 划掉过的不再提；和模板撞车的（模型也提「外卖不超过 3 次」）不重复列，列表里的 key 也是 Dismissible 的 key，重了会炸
      final have = candidates.map(candidateKey).toSet();
      final fresh = _withoutDismissed(extra).where((c) => have.add(candidateKey(c))).toList();
      if (fresh.isNotEmpty) {
        candidates = [...candidates, ...fresh.take(3)];
        candidatesFromModel = true;
        notifyListeners();
      }
    } catch (_) {
      // 模型不给力就只有模板
    }
  }

  /// 把候选（或用户改过数字的候选 [t]，原候选传 [replacing]）加入本周。原候选一并从列表拿掉并记成划掉——
  /// 不记的话下次打开候选重算，「外卖不超过 3 次」改成 2 次加进本周后，3 次那条又会冒出来。
  Future<WeeklyTask> acceptCandidate(TaskTemplate t, {TaskTemplate? replacing, String? rewardGoalId, int rewardMinor = 0, String source = 'template'}) async {
    final task = ledger.tasks.create(week: thisWeek, kind: t.kind, params: t.params, title: t.title, rewardGoalId: rewardGoalId, rewardMinor: rewardMinor, source: source);
    final gone = {candidateKey(t), if (replacing != null) candidateKey(replacing)};
    candidates = candidates.where((c) => c != t && c != replacing).toList();
    await _rememberDismissed(gone);
    app.touch();
    return task;
  }

  /// 用户划掉一个候选：本周不再出现（换周重算）。
  Future<void> dismissCandidate(TaskTemplate t) async {
    candidates = candidates.where((c) => c != t).toList();
    notifyListeners(); // 先把它从列表拿掉再落盘：Dismissible 划完下一帧就得不在树里
    await _rememberDismissed({candidateKey(t)});
  }

  List<TaskTemplate> _withoutDismissed(List<TaskTemplate> list) => list.where((c) => !_dismissedCandidates.contains(candidateKey(c))).toList();

  void _loadDismissed(SharedPreferences p, String week) {
    try {
      final raw = p.getString(_dismissedKey);
      if (raw == null) {
        _dismissedCandidates = const {};
        return;
      }
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      _dismissedCandidates = j['week'] == week ? ((j['keys'] as List?) ?? const []).map((k) => '$k').toSet() : const {};
    } catch (_) {
      _dismissedCandidates = const {};
    }
  }

  Future<void> _rememberDismissed(Set<String> keys) async {
    _dismissedCandidates = {..._dismissedCandidates, ...keys};
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_dismissedKey, jsonEncode({'week': thisWeek, 'keys': _dismissedCandidates.toList()}));
    } catch (_) {
      // 记不下就只是这次会话里不再出现
    }
  }

  Future<void> removeTask(String id) async {
    ledger.tasks.delete(id);
    app.touch();
  }

  // ---------------------------------------------------------------- 仪式

  /// 启动时跑一遍：到期定存、发薪日（按画像 / 推断的日子）、月末复盘。
  Future<void> runRituals() async {
    final today = _today;
    // 到期定存（虚拟直接记，真实进收件箱）
    for (final d in ledger.goals.dueFixed(today: today)) {
      await deposit(d.goal, d.amountMinor, fingerprint: d.fingerprint, note: d.note, source: Source.recurring);
    }
    if (!enabled) return;
    try {
      final p = await SharedPreferences.getInstance();
      // 发薪日：今天是发薪日且这个月还没发过卡（真实工资到账那条路在 onIncomeCommitted）
      if (rituals['payday'] == true && Wealth(ledger).isPayday(today: today) && p.getString('payday_ritual_month') != today.substring(0, 7)) {
        final est = _estimatedSalary();
        if (est > 0) {
          await p.setString('payday_ritual_month', today.substring(0, 7));
          await proposePaydayPlan(est, note: '按往常的工资估的');
        }
      }
      // 月末复盘：进入新的一月第一次打开
      final ym = today.substring(0, 7);
      final lastReview = p.getString('monthly_review_done');
      if (rituals['monthly'] == true && lastReview != ym) {
        final t = DateTime.parse('${today}T00:00:00');
        final prev = DateTime(t.year, t.month - 1, 1);
        // 上个月有记录才复盘
        if (ledger.listTransactions(from: prev.toUtc().subtract(const Duration(days: 1)), to: DateTime(t.year, t.month, 1).toUtc().add(const Duration(days: 1)), limit: 1).isNotEmpty) {
          await p.setString('monthly_review_done', ym);
          final text = await buildMonthlyReview(prev.year, prev.month);
          pendingMessages.add((text: app.replier.template(PersonaEvent.monthlyReview, label: text), sticker: null, meta: '${prev.month} 月复盘'));
        } else {
          await p.setString('monthly_review_done', ym);
        }
      }
    } catch (_) {}
  }

  int _estimatedSalary() {
    final t = DateTime.parse('${_today}T00:00:00Z');
    final amounts = <int>[];
    for (var i = 1; i <= 3; i++) {
      final m = DateTime.utc(t.year, t.month - i, 1);
      final last = DateTime.utc(m.year, m.month + 1, 0);
      var best = 0;
      for (final tx in ledger.listTransactions(from: m.subtract(const Duration(days: 1)), to: last.add(const Duration(days: 2)), type: TransactionType.income, limit: 1 << 30)) {
        if ((tx.categoryId == 'salary' || tx.categoryId == 'bonus') && tx.amountMinor > best) best = tx.amountMinor;
      }
      if (best > 0) amounts.add(best);
    }
    if (amounts.isEmpty) return 0;
    amounts.sort();
    return amounts[amounts.length ~/ 2];
  }

  /// 工资到账（用户确认了一笔工资 / 奖金收入）→ 发薪日仪式：按目标顺序分钱，一组转账草稿进收件箱。
  Future<void> onIncomeCommitted(Transaction t) async {
    if (!enabled || rituals['payday'] != true) return;
    if (t.type != TransactionType.income) return;
    if (!(t.categoryId == 'salary' || t.categoryId == 'bonus')) return;
    if (t.amountMinor < 100000) return; // 太小的不算工资
    try {
      final p = await SharedPreferences.getInstance();
      final key = 'payday_ritual_tx';
      if (p.getString(key) == t.id) return;
      await p.setString(key, t.id);
      await p.setString('payday_ritual_month', _today.substring(0, 7));
    } catch (_) {}
    await proposePaydayPlan(t.amountMinor, fromAccountId: t.accountId);
  }

  /// 发薪日分钱：每个目标一笔转账草稿，同一 group；虚拟锁仓的一键确认即记账，真锁仓的确认前要真转。
  Future<List<Draft>> proposePaydayPlan(int incomeMinor, {String? fromAccountId, String? note}) async {
    final plan = ledger.goals.paydayPlan(incomeMinor);
    if (plan.isEmpty) return const [];
    final from = fromAccountId ?? ledger.profile.salaryAccountId ?? app.defaultAccountId;
    if (from == null) return const [];
    final month = _today.substring(0, 7);
    final inputs = <DraftInput>[];
    for (final a in plan) {
      // 每月定额和「到期定存」共用一个指纹：发薪日先到就在这里存，定存那天自动跳过；反过来也一样，不会一期存两次
      final fp = a.rule.kind == GoalRuleKind.fixed ? GoalStore.fixedFingerprint(a.goal.id, a.rule, _today) : 'goal:${a.goal.id}:payday:$month';
      if (ledger.hasFingerprint(fp)) continue;
      inputs.add(DraftInput(payload: ledger.goals.depositPayload(a.goal, a.amountMinor, fromAccountId: from, note: '发薪日 → 「${a.goal.name}」${a.short ? '（钱不够，先保前面的目标，只给 ${fmtMoney(a.amountMinor, a.goal.currency)}）' : ''}'), eventFingerprint: fp, fingerprintIsExact: true, confidence: 0.9));
    }
    if (inputs.isEmpty) return const [];
    final drafts = ledger.propose(inputs, source: Source.recurring, actor: Actor.automation, interpreter: 'payday');
    final total = plan.fold(0, (a, b) => a + b.amountMinor);
    final m = metrics;
    final left = incomeMinor - total;
    pendingMessages.add((
      text: '${app.replier.template(PersonaEvent.payday, n: total ~/ 100)}${note != null ? '（$note）' : ''}\n'
          '${plan.map((a) => '「${a.goal.name}」+${fmtMoney(a.amountMinor, a.goal.currency)}${a.short ? '（想要 ${fmtMoney(a.wantedMinor, a.goal.currency)}，钱不够先保前面的）' : ''}').join('\n')}\n'
          '剩下可花 ${fmtMoney(left, 'CNY')}${m != null ? '，到 ${m.payday.substring(5).replaceFirst('-', '/')} 平均每天 ${fmtMoney((left / m.daysToPayday).floor(), 'CNY')}' : ''}。到收件箱一键确认。',
      sticker: '💰',
      meta: '发薪日仪式 · ${drafts.length} 笔转账待确认',
    ));
    app.touch();
    return drafts;
  }

  /// 月度复盘正文（规则生成，真数）；有模型时让人格润色一段（只发这段文字，不发账本）。
  Future<String> buildMonthlyReview(int year, int month) async {
    final from = DateTime.utc(year, month, 1);
    final to = DateTime.utc(year, month + 1, 0);
    String fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final txs = ledger.listTransactions(from: from.subtract(const Duration(days: 1)), to: to.add(const Duration(days: 2)), limit: 1 << 30).where((t) {
      final d = t.occurredAt.localDate;
      return d.compareTo(fmt(from)) >= 0 && d.compareTo(fmt(to)) <= 0 && t.currency == 'CNY';
    }).toList();
    var income = 0;
    var expense = 0;
    final byCat = <String, int>{};
    for (final t in txs) {
      if (t.type == TransactionType.income) income += t.amountMinor;
      if (t.type == TransactionType.expense) {
        expense += t.amountMinor;
        byCat[t.categoryId ?? '-'] = (byCat[t.categoryId ?? '-'] ?? 0) + t.amountMinor;
      }
      if (t.type == TransactionType.refund) expense -= t.amountMinor;
    }
    final top = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final lines = <String>[
      '$month 月：收入 ${fmtMoney(income, 'CNY')}，支出 ${fmtMoney(expense, 'CNY')}${income > 0 ? '，存下 ${((income - expense) / income * 100).toStringAsFixed(0)}%' : ''}。',
      if (top.isNotEmpty) '花得最多的是${top.take(3).map((e) => '${app.categoryName(e.key)} ${fmtMoney(e.value, 'CNY')}').join('、')}。',
      for (final p in goals.where((p) => p.goal.kind == GoalKind.wish)) describe(p),
      if (metrics?.debtTier != null) '净资产 ${fmtMoney(metrics!.netWorthMinor, 'CNY')} 是负的，称号是「${metrics!.debtTier!.title}」（负翁档按欠款分：小负翁 < 1 万、负翁 1 万起、大负翁 10 万起、百万负翁、千万负翁），再还 ${fmtMoney(metrics!.toLighterDebtTierMinor!, 'CNY')} ${metrics!.debtTier!.lighter == null ? '净资产转正' : '降到「${metrics!.debtTier!.lighter!.title}」'}。',
      if (metrics?.level != null) '${metrics!.inDebt ? '等级' : '现在的称号是「${metrics!.level!.title}」、等级'}「${metrics!.level!.name}」（够花 ${metrics!.runwayMonths!.toStringAsFixed(1)} 个月）${metrics!.toNextLevelMinor != null && metrics!.toNextLevelMinor! > 0 ? '，再攒 ${fmtMoney(metrics!.toNextLevelMinor!, 'CNY')} 升一级' : ''}。',
    ];
    final settled = ledger.tasks.list(limit: 100).where((t) => t.week.startsWith('$year-${month.toString().padLeft(2, '0')}') && t.result != TaskResult.pending).toList();
    if (settled.isNotEmpty) lines.add('周任务 ${settled.where((t) => t.result == TaskResult.done).length} / ${settled.length} 完成。');
    if (top.isNotEmpty) lines.add('下个月试试：把「${app.categoryName(top.first.key)}」压到 ${fmtMoney((top.first.value * 0.85).round() ~/ 100 * 100, 'CNY')} 以内。');
    final raw = lines.join('\n');
    final p = app.taskProvider;
    if (p == null) return raw;
    try {
      final r = await p.complete(system: assemblePrompt(app.persona), user: '把下面这份月度复盘用你的口吻重讲一遍，数字一个都不能改、不能多加，不超过 150 字：\n$raw', timeout: const Duration(seconds: 20));
      final t = r.text.trim();
      return t.isEmpty ? raw : '$t\n\n—\n$raw';
    } catch (_) {
      return raw;
    }
  }
}
