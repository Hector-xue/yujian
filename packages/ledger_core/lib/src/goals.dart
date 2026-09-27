import 'dart:convert';

import 'changes.dart';
import 'db/database.dart';
import 'errors.dart';
import 'ids.dart';
import 'ledger.dart';
import 'models/enums.dart';
import 'models/transaction.dart';
import 'money.dart';
import 'occurred_at.dart';

/// 目标（财富游戏层的唯一实体）：心愿 / 应急金 / 还清 / 里程碑。
/// 进度全部从账本推导：心愿看锁仓账户余额，应急金看生存月数，还清看负债账户余额，里程碑看净资产。
enum GoalKind { wish, emergency, payoff, milestone }

enum GoalStatus { active, done, archived }

/// 存入规则的种类：定额 / 工资到账比例 / 零头凑整（周结）/ 周任务奖励。
enum GoalRuleKind { fixed, salaryPct, roundup, reward }

class GoalRule {
  final GoalRuleKind kind;
  final int amountMinor; // fixed / reward：每次金额
  final String every; // fixed：monthly | weekly
  final int day; // fixed：monthly 时 1–28 的几号；weekly 时 1–7（周一=1）
  final double pct; // salaryPct：0–100
  final int roundTo; // roundup：凑整到多少最小单位（100 = 整元，1000 = 整十元）
  final String? fromAccountId; // 从哪个账户存；空 = 默认账户

  const GoalRule({required this.kind, this.amountMinor = 0, this.every = 'monthly', this.day = 1, this.pct = 0, this.roundTo = 1000, this.fromAccountId});

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        if (amountMinor != 0) 'amount_minor': amountMinor,
        if (kind == GoalRuleKind.fixed) 'every': every,
        if (kind == GoalRuleKind.fixed) 'day': day,
        if (kind == GoalRuleKind.salaryPct) 'pct': pct,
        if (kind == GoalRuleKind.roundup) 'round_to': roundTo,
        if (fromAccountId != null) 'from_account_id': fromAccountId,
      };

  factory GoalRule.fromJson(Map<String, Object?> j) => GoalRule(
        kind: GoalRuleKind.values.byName(j['kind'] as String),
        amountMinor: (j['amount_minor'] as num?)?.toInt() ?? 0,
        every: (j['every'] as String?) ?? 'monthly',
        day: (j['day'] as num?)?.toInt() ?? 1,
        pct: (j['pct'] as num?)?.toDouble() ?? 0,
        roundTo: (j['round_to'] as num?)?.toInt() ?? 1000,
        fromAccountId: j['from_account_id'] as String?,
      );
}

class Goal {
  final String id;
  final GoalKind kind;
  final String name;
  final String? emoji;
  final String? cover; // 封面图路径（本机）
  final int targetMinor;
  final String currency;
  final String? deadline; // yyyy-MM-dd
  final String? vaultAccountId; // 锁仓账户：虚拟 = vault:<id>；真实 = 用户账户
  final String? linkedAccountId; // payoff：负债账户
  final int priority; // 越小越靠前
  final GoalStatus status;
  final List<GoalRule> rules;
  final int? doneAt;
  final int createdAt;
  final int updatedAt;

  const Goal({
    required this.id,
    required this.kind,
    required this.name,
    this.emoji,
    this.cover,
    required this.targetMinor,
    required this.currency,
    this.deadline,
    this.vaultAccountId,
    this.linkedAccountId,
    required this.priority,
    required this.status,
    required this.rules,
    this.doneAt,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isVirtualVault => vaultAccountId != null && vaultAccountId!.startsWith('vault:');

  /// 有锁仓（心愿 / 里程碑可存钱；应急金也可以给自己攒一个锁仓）。
  bool get hasVault => vaultAccountId != null;

  factory Goal.fromRow(Map<String, Object?> r) => Goal(
        id: r['id'] as String,
        kind: GoalKind.values.asNameMap()[r['kind']] ?? GoalKind.wish, // 未知值（新版本同步来的）不崩
        name: r['name'] as String,
        emoji: r['emoji'] as String?,
        cover: r['cover'] as String?,
        targetMinor: r['target_minor'] as int,
        currency: r['currency'] as String,
        deadline: r['deadline'] as String?,
        vaultAccountId: r['vault_account_id'] as String?,
        linkedAccountId: r['linked_account_id'] as String?,
        priority: r['priority'] as int,
        status: GoalStatus.values.asNameMap()[r['status']] ?? GoalStatus.active,
        // 认不出的规则种类（新版本加的）跳过，不猜它是定额还是比例——猜错了会替用户存钱
        rules: [for (final j in (jsonDecode((r['rules'] as String?) ?? '[]') as List)) if (GoalRuleKind.values.asNameMap().containsKey((j as Map)['kind'])) GoalRule.fromJson(j.cast<String, Object?>())],
        doneAt: r['done_at'] as int?,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'emoji': emoji,
        'cover': cover,
        'target_minor': targetMinor,
        'currency': currency,
        'deadline': deadline,
        'vault_account_id': vaultAccountId,
        'linked_account_id': linkedAccountId,
        'priority': priority,
        'status': status.name,
        'rules': [for (final r in rules) r.toJson()],
        'done_at': doneAt,
      };
}

/// 一个目标当前的进度（全是推导值，不落库）。
class GoalProgress {
  final Goal goal;
  final int savedMinor; // 已攒 / 已还 / 当前值
  final int targetMinor;
  final double? paceMinorPerDay; // 最近 30 天的存入速度；没有存入记录 = null
  final int? etaDays; // 按当前速度还要几天；算不出 = null
  final int? behindDays; // 比 deadline 晚几天（正数 = 晚）；没 deadline 或算不出 = null
  const GoalProgress({required this.goal, required this.savedMinor, required this.targetMinor, this.paceMinorPerDay, this.etaDays, this.behindDays});

  double get ratio => targetMinor <= 0 ? 0 : (savedMinor / targetMinor).clamp(0.0, 1.0);
  int get remainingMinor => (targetMinor - savedMinor).clamp(0, maxMinor);
  bool get reached => targetMinor > 0 && savedMinor >= targetMinor;

  /// 已过的阶段里程碑（10 / 25 / 50 / 75 / 100）。
  int get milestone {
    final p = ratio * 100;
    for (final m in const [100, 75, 50, 25, 10]) {
      if (p >= m) return m;
    }
    return 0;
  }
}

/// 发薪日分钱方案里的一项。
class PaydayAllocation {
  final Goal goal;
  final GoalRule rule;
  final int wantedMinor;
  final int amountMinor; // 实际分到（钱不够时少于 wanted）
  const PaydayAllocation({required this.goal, required this.rule, required this.wantedMinor, required this.amountMinor});
  bool get short => amountMinor < wantedMinor;
}

/// 到期的存入（定额 / 零头周结）：调用方拿 payload 去 propose / commit。
class DueDeposit {
  final Goal goal;
  final GoalRule rule;
  final int amountMinor;
  final String fingerprint;
  final String note;
  const DueDeposit({required this.goal, required this.rule, required this.amountMinor, required this.fingerprint, required this.note});
}

class GoalStore {
  final Ledger ledger;
  final LedgerDatabase _db;
  final int Function() _nowMs;
  final ChangeLog? _changes;
  GoalStore(this.ledger, this._db, this._nowMs, [this._changes]);

  static String vaultIdOf(String goalId) => 'vault:$goalId';

  // ------------------------------------------------------------------ CRUD

  Goal create({
    required GoalKind kind,
    required String name,
    required int targetMinor,
    String currency = 'CNY',
    String? emoji,
    String? cover,
    String? deadline,
    /// 真实锁仓账户；null 且 [withVault] 时建一个虚拟锁仓账户。
    String? vaultAccountId,
    bool withVault = true,
    String? linkedAccountId,
    List<GoalRule> rules = const [],
    String? id,
  }) {
    if (name.trim().isEmpty) throw ValidationException('name', 'required');
    if (targetMinor <= 0 && kind != GoalKind.payoff) throw ValidationException('target_minor', 'must be > 0');
    if (!Currency.isKnown(currency)) throw ValidationException('currency', 'unknown');
    if (kind == GoalKind.payoff) {
      if (linkedAccountId == null) throw ValidationException('linked_account_id', 'required for payoff');
      final a = ledger.getAccount(linkedAccountId);
      if (a.type != AccountType.creditCard && a.type != AccountType.payable) throw ValidationException('linked_account_id', 'payoff needs a credit_card or payable account');
    }
    if (vaultAccountId != null) {
      final a = ledger.getAccount(vaultAccountId);
      if (a.currency != currency) throw ValidationException('vault_account_id', 'currency mismatch');
      if (!canBeVault(a.type)) throw ValidationException('vault_account_id', 'vault must be a cash / bank / e-wallet / investment account');
    }
    final gid = id ?? Ulid.next();
    final ts = _nowMs();
    return _db.transaction(() {
      String? vault = vaultAccountId;
      if (vault == null && withVault && kind != GoalKind.payoff) {
        vault = vaultIdOf(gid);
        if (ledger.account(vault) == null) {
          ledger.createAccount(id: vault, name: name.trim(), type: AccountType.vault, currency: currency, icon: emoji);
        }
      }
      final prio = (_db.select('SELECT COALESCE(MAX(priority), -1) + 1 AS p FROM goals').first['p'] as int);
      final target = kind == GoalKind.payoff ? _payoffTarget(linkedAccountId!) : targetMinor;
      _db.execute(
        'INSERT INTO goals(id,kind,name,emoji,cover,target_minor,currency,deadline,vault_account_id,linked_account_id,priority,status,rules,done_at,created_at,updated_at) '
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,'active',?,NULL,?,?)",
        [gid, kind.name, name.trim(), emoji, cover, target, currency, deadline, vault, linkedAccountId, prio, jsonEncode([for (final r in rules) r.toJson()]), ts, ts],
      );
      final g = get(gid);
      ledger.auditGoal('goal.create', gid, after: g.toJson());
      _changes?.record('goal', gid, g.toJson());
      return g;
    });
  }

  int _payoffTarget(String accountId) {
    final b = ledger.balance(accountId).minor;
    return b < 0 ? -b : 0;
  }

  Goal get(String id) {
    final r = _db.select('SELECT * FROM goals WHERE id = ?', [id]);
    if (r.isEmpty) throw NotFoundException('goal', id);
    return Goal.fromRow(r.first);
  }

  Goal? find(String id) {
    final r = _db.select('SELECT * FROM goals WHERE id = ?', [id]);
    return r.isEmpty ? null : Goal.fromRow(r.first);
  }

  List<Goal> list({bool activeOnly = true}) =>
      _db.select("SELECT * FROM goals ${activeOnly ? "WHERE status = 'active'" : ''} ORDER BY priority, created_at").map(Goal.fromRow).toList();

  /// 按 vault 账户找目标（兑现支出 / 存入转账落在哪个目标）。
  Goal? byVault(String accountId) {
    final r = _db.select('SELECT * FROM goals WHERE vault_account_id = ? AND status != ? ORDER BY created_at DESC LIMIT 1', [accountId, 'archived']);
    return r.isEmpty ? null : Goal.fromRow(r.first);
  }

  Goal update(String id, {String? name, String? emoji, String? cover, int? targetMinor, String? deadline, bool clearDeadline = false, List<GoalRule>? rules, GoalStatus? status}) {
    final g = get(id);
    final before = g.toJson();
    _db.execute(
      'UPDATE goals SET name=?, emoji=?, cover=?, target_minor=?, deadline=?, rules=?, status=?, done_at=?, updated_at=? WHERE id=?',
      [
        name?.trim() ?? g.name,
        emoji ?? g.emoji,
        cover ?? g.cover,
        targetMinor ?? g.targetMinor,
        clearDeadline ? null : (deadline ?? g.deadline),
        jsonEncode([for (final r in rules ?? g.rules) r.toJson()]),
        (status ?? g.status).name,
        (status ?? g.status) == GoalStatus.done ? (g.doneAt ?? _nowMs()) : (status == GoalStatus.active ? null : g.doneAt),
        _nowMs(),
        id,
      ],
    );
    if (name != null && g.isVirtualVault) {
      _db.execute('UPDATE accounts SET name = ?, updated_at = ? WHERE id = ?', [name.trim(), _nowMs(), g.vaultAccountId]);
    }
    final after = get(id);
    ledger.auditGoal(status != null && status != g.status ? 'goal.${status.name}' : 'goal.update', id, before: before, after: after.toJson());
    _changes?.record('goal', id, after.toJson());
    return after;
  }

  /// 真删一个目标（不是归档）。锁仓账户不动——里面可能还有钱，归档那条路才处理释放。
  void delete(String id) {
    final g = get(id);
    _db.execute('DELETE FROM goals WHERE id = ?', [id]);
    ledger.auditGoal('goal.delete', id, before: g.toJson());
    _changes?.record('goal', id, null, deleted: true);
  }

  /// 用户手删一个目标：目标真删，虚拟锁仓账户跟着清——没有任何记录的真删，存过钱的归档留历史（和删账户同一条规矩）。
  /// 锁仓里还有钱时拒绝（调用方先释放回来源，见 App 的 GameLayer.release）；真锁仓是用户自己的账户，不碰。
  GoalRemoval remove(String id) {
    final g = get(id);
    if (g.isVirtualVault && savedMinor(g) > 0) throw InvalidStateException('vault still holds money; release it first');
    return ledger.database.transaction(() {
      delete(id);
      var vaultDeleted = false;
      var postings = 0;
      if (g.isVirtualVault && ledger.account(g.vaultAccountId!) != null) {
        postings = ledger.accountPostingCount(g.vaultAccountId!);
        if (postings > 0) {
          if (!ledger.getAccount(g.vaultAccountId!).isArchived) ledger.archiveAccount(g.vaultAccountId!);
        } else {
          ledger.deleteAccount(g.vaultAccountId!);
          vaultDeleted = true;
        }
      }
      return GoalRemoval(vaultDeleted: vaultDeleted, postingCount: postings);
    });
  }

  /// 换锁仓：[vaultAccountId] 为 null = 改回虚拟锁仓（没有就建一个）。不动钱，调用方自己处理释放 / 转入。
  Goal setVault(String id, String? vaultAccountId) {
    final g = get(id);
    final before = g.toJson();
    var vault = vaultAccountId;
    if (vault == null) {
      vault = vaultIdOf(id);
      if (ledger.account(vault) == null) ledger.createAccount(id: vault, name: g.name, type: AccountType.vault, currency: g.currency, icon: g.emoji);
    } else {
      final a = ledger.getAccount(vault);
      if (a.currency != g.currency) throw ValidationException('vault_account_id', 'currency mismatch');
      if (!canBeVault(a.type)) throw ValidationException('vault_account_id', 'vault must be a cash / bank / e-wallet / investment account');
    }
    _db.execute('UPDATE goals SET vault_account_id = ?, updated_at = ? WHERE id = ?', [vault, _nowMs(), id]);
    final after = get(id);
    ledger.auditGoal('goal.update', id, before: before, after: after.toJson());
    _changes?.record('goal', id, after.toJson());
    return after;
  }

  /// 拖动排序：按给定顺序重排 priority。
  void reorder(List<String> ids) {
    _db.transaction(() {
      for (var i = 0; i < ids.length; i++) {
        _db.execute('UPDATE goals SET priority = ?, updated_at = ? WHERE id = ?', [i, _nowMs(), ids[i]]);
        final g = find(ids[i]);
        if (g != null) _changes?.record('goal', g.id, g.toJson());
      }
    });
  }

  /// 同步应用远端行（虚拟锁仓账户随 account 实体自己同步过来）。
  void upsertRaw(Map<String, Object?> p) => _db.execute(
        'INSERT OR REPLACE INTO goals(id,kind,name,emoji,cover,target_minor,currency,deadline,vault_account_id,linked_account_id,priority,status,rules,done_at,created_at,updated_at) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,COALESCE((SELECT created_at FROM goals WHERE id = ?),?),?)',
        [p['id'], p['kind'], p['name'], p['emoji'], p['cover'], p['target_minor'], p['currency'], p['deadline'], p['vault_account_id'], p['linked_account_id'], p['priority'] ?? 0, p['status'] ?? 'active', jsonEncode(p['rules'] ?? const []), p['done_at'], p['id'], _nowMs(), _nowMs()],
      );
  void deleteRaw(String id) => _db.execute('DELETE FROM goals WHERE id = ?', [id]);

  // -------------------------------------------------------------- progress

  /// 锁仓里的钱（心愿 / 里程碑 / 应急金的锁仓）。
  /// 真锁仓能放在哪类账户：存钱的账户（现金 / 银行卡 / 钱包 / 投资）。信用卡 / 贷款 / 借出去的当锁仓，「已攒」就成了欠款或别人的钱。
  static bool canBeVault(AccountType t) => t == AccountType.cash || t == AccountType.bank || t == AccountType.eWallet || t == AccountType.investment || t == AccountType.vault;

  int savedMinor(Goal g) => g.vaultAccountId == null ? 0 : ledger.balance(g.vaultAccountId!).minor.clamp(0, maxMinor);

  /// 存入记录：转进锁仓账户的 transfer（最新在前）。
  List<Transaction> deposits(String goalId, {int limit = 500}) {
    final g = get(goalId);
    if (g.vaultAccountId == null) return const [];
    return [
      for (final t in ledger.listTransactions(accountId: g.vaultAccountId, type: TransactionType.transfer, limit: limit))
        if (t.toAccountId == g.vaultAccountId) t,
    ];
  }

  /// 从锁仓账户花出去的（兑现）。
  List<Transaction> redemptions(String goalId, {int limit = 500}) {
    final g = get(goalId);
    if (g.vaultAccountId == null) return const [];
    return [
      for (final t in ledger.listTransactions(accountId: g.vaultAccountId, limit: limit))
        if (t.type == TransactionType.expense || (t.type == TransactionType.transfer && t.accountId == g.vaultAccountId)) t,
    ];
  }

  GoalProgress progress(Goal g, {required String today, int? liquidMinor, int? monthlySpendMinor, int? netWorthMinor}) {
    int saved;
    int target = g.targetMinor;
    switch (g.kind) {
      case GoalKind.wish:
        saved = savedMinor(g);
      case GoalKind.emergency:
        // 应急金：锁仓有钱按锁仓，没锁仓按没锁进别的目标的流动资产（调用方传 WealthMetrics.freeLiquidMinor；目标额创建时冻结）
        saved = g.vaultAccountId != null ? savedMinor(g) : (liquidMinor ?? 0);
      case GoalKind.payoff:
        // 「还欠」必须等于这个账户此刻欠多少：信用卡边还边刷，欠款可能涨过建目标时的数——这时按现在的欠款算，
        // 已还记 0，不能还停在建目标时的数（负债页写欠 8618，目标条还写欠 8118）
        final owed = g.linkedAccountId == null ? 0 : _payoffTarget(g.linkedAccountId!);
        target = owed > g.targetMinor ? owed : g.targetMinor;
        saved = target - owed;
      case GoalKind.milestone:
        saved = (netWorthMinor ?? 0).clamp(0, maxMinor);
    }
    // 速度：最近 30 天存入之和 / 30
    double? pace;
    int? eta;
    int? behind;
    if (g.vaultAccountId != null && g.kind != GoalKind.payoff) {
      final t = _parse(today);
      final from = t.subtract(const Duration(days: 30));
      var sum = 0;
      for (final d in deposits(g.id)) {
        if (d.occurredAt.localDate.compareTo(_fmt(from)) >= 0) sum += d.amountMinor;
      }
      if (sum > 0) {
        pace = sum / 30;
        final remaining = target - saved;
        eta = remaining <= 0 ? 0 : (remaining / pace).ceil();
        if (g.deadline != null) {
          final dl = _parse(g.deadline!);
          behind = t.add(Duration(days: eta)).difference(dl).inDays;
        }
      }
    }
    return GoalProgress(goal: g, savedMinor: saved, targetMinor: target, paceMinorPerDay: pace, etaDays: eta, behindDays: behind);
  }

  // ------------------------------------------------------------- payloads

  /// 存入 = 一笔 transfer 到锁仓账户。调用方按锁仓是虚是真决定直接 commit 还是进收件箱。
  Map<String, Object?> depositPayload(Goal g, int amountMinor, {required String fromAccountId, DateTime? at, String? note}) {
    if (g.vaultAccountId == null) throw ValidationException('vault_account_id', 'goal has no vault');
    if (amountMinor <= 0) throw ValidationException('amount_minor', 'must be > 0');
    final when = at ?? ledger.now();
    return {
      'type': 'transfer',
      'amount_minor': amountMinor,
      'currency': g.currency,
      'account_id': fromAccountId,
      'to_account_id': g.vaultAccountId,
      'description': note ?? '存入「${g.name}」',
      'occurred_at': OccurredAt(when, when.timeZoneOffset.inMinutes).toIso8601String(),
      'metadata': {'goal_id': g.id, 'goal_kind': 'deposit'},
    };
  }

  /// 兑现 = 从锁仓账户记一笔支出（可以多笔）。
  Map<String, Object?> redeemPayload(Goal g, int amountMinor, {required String categoryId, String? merchant, String? description, DateTime? at}) {
    if (g.vaultAccountId == null) throw ValidationException('vault_account_id', 'goal has no vault');
    if (amountMinor <= 0) throw ValidationException('amount_minor', 'must be > 0');
    final when = at ?? ledger.now();
    return {
      'type': 'expense',
      'amount_minor': amountMinor,
      'currency': g.currency,
      'account_id': g.vaultAccountId,
      'category_id': categoryId,
      if (merchant != null) 'merchant': merchant,
      'description': description ?? g.name,
      'occurred_at': OccurredAt(when, when.timeZoneOffset.inMinutes).toIso8601String(),
      'metadata': {'goal_id': g.id, 'goal_kind': 'redeem'},
    };
  }

  /// 释放锁仓：把锁仓余额按存入来源比例转回去；算不清（没有存入记录）就整笔回 [fallbackAccountId]。
  List<Map<String, Object?>> releasePayloads(Goal g, {required String fallbackAccountId}) {
    if (g.vaultAccountId == null) return const [];
    final total = savedMinor(g);
    if (total <= 0) return const [];
    final bySource = <String, int>{};
    for (final d in deposits(g.id)) {
      if (ledger.account(d.accountId)?.isArchived == false) bySource[d.accountId] = (bySource[d.accountId] ?? 0) + d.amountMinor;
    }
    final sum = bySource.values.fold(0, (a, b) => a + b);
    final out = <Map<String, Object?>>[];
    final when = ledger.now();
    Map<String, Object?> back(String to, int amount) => {
          'type': 'transfer',
          'amount_minor': amount,
          'currency': g.currency,
          'account_id': g.vaultAccountId,
          'to_account_id': to,
          'description': '「${g.name}」释放',
          'occurred_at': OccurredAt(when, when.timeZoneOffset.inMinutes).toIso8601String(),
          'metadata': {'goal_id': g.id, 'goal_kind': 'release'},
        };
    if (sum <= 0) return [back(fallbackAccountId, total)];
    var left = total;
    final entries = bySource.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      // 前面的向下取整、最后一笔拿余数：加起来正好等于锁仓余额（四舍五入会多退 1 分，把锁仓退成负数）
      final amount = i == entries.length - 1 ? left : (total * entries[i].value ~/ sum);
      if (amount > 0) out.add(back(entries[i].key, amount));
      left -= amount;
    }
    return out;
  }

  // ---------------------------------------------------------------- rules

  /// 发薪日分钱：按优先级依次满足各目标的比例 / 定额（monthly）规则；[availableMinor] 不够时后面的少拿。
  List<PaydayAllocation> paydayPlan(int incomeMinor, {int? availableMinor}) {
    var left = availableMinor ?? incomeMinor;
    final out = <PaydayAllocation>[];
    for (final g in list()) {
      if (g.vaultAccountId == null) continue;
      final p = progress(g, today: _fmt(ledger.now()));
      if (p.reached) continue;
      var room = p.remainingMinor; // 同一个目标的几条规则共用还差的额度：「工资 20%」加「每月 500」加起来也不超过目标
      for (final r in g.rules) {
        int wanted;
        if (r.kind == GoalRuleKind.salaryPct) {
          wanted = (incomeMinor * r.pct / 100).round();
        } else if (r.kind == GoalRuleKind.fixed && r.every == 'monthly') {
          wanted = r.amountMinor;
        } else {
          continue;
        }
        wanted = wanted.clamp(0, room);
        if (wanted <= 0) continue;
        final amount = wanted.clamp(0, left.clamp(0, maxMinor));
        out.add(PaydayAllocation(goal: g, rule: r, wantedMinor: wanted, amountMinor: amount));
        left -= amount;
        room -= wanted;
      }
    }
    return out;
  }

  /// 定额存入的指纹：每月一期 = `goal:<id>:fixed:yyyy-MM`，每周一期 = `goal:<id>:fixed:<那一周约定的日子>`。
  /// 发薪日分钱里的每月定额也用同一个指纹——两条路谁先到谁存，另一条自动跳过，不会一期存两次。
  static String fixedFingerprint(String goalId, GoalRule r, String today) {
    final t = _parse(today);
    if (r.every == 'weekly') {
      final monday = t.subtract(Duration(days: t.weekday - 1));
      return 'goal:$goalId:fixed:${_fmt(monday.add(Duration(days: r.day.clamp(1, 7) - 1)))}';
    }
    return 'goal:$goalId:fixed:${t.year}-${t.month.toString().padLeft(2, '0')}';
  }

  /// 到期的定额存入：这一期约定的日子已经到了（含今天）、这一期还没存过、且那天目标已经建好。
  /// 以前只认「今天正好是那天」，那天没打开 App 这一期就漏了；现在当期内任何一天打开都会补上。
  List<DueDeposit> dueFixed({required String today}) {
    final t = _parse(today);
    final out = <DueDeposit>[];
    for (final g in list()) {
      if (g.vaultAccountId == null) continue;
      final p = progress(g, today: today);
      if (p.reached) continue;
      final created = DateTime.fromMillisecondsSinceEpoch(g.createdAt);
      final createdDay = DateTime.utc(created.year, created.month, created.day);
      for (final r in g.rules) {
        if (r.kind != GoalRuleKind.fixed || r.amountMinor <= 0) continue;
        DateTime due;
        if (r.every == 'weekly') {
          final monday = t.subtract(Duration(days: t.weekday - 1));
          due = monday.add(Duration(days: r.day.clamp(1, 7) - 1));
        } else {
          final last = DateTime.utc(t.year, t.month + 1, 0).day;
          due = DateTime.utc(t.year, t.month, r.day > last ? last : r.day);
        }
        if (due.isAfter(t) || due.isBefore(createdDay)) continue; // 还没到 / 那天目标还没建（建目标当月不倒扣）
        final fp = fixedFingerprint(g.id, r, today);
        if (ledger.hasFingerprint(fp)) continue;
        out.add(DueDeposit(goal: g, rule: r, amountMinor: r.amountMinor.clamp(0, p.remainingMinor), fingerprint: fp, note: '「${g.name}」${r.every == 'weekly' ? '每周' : '每月'}定存'));
      }
    }
    return out;
  }

  /// 上一周的零头周结：一周里每笔支出的零头之和，一笔存入。[weekMonday] 是那一周的周一。
  List<DueDeposit> roundupDue({required String weekMonday}) {
    final monday = _parse(weekMonday);
    final sunday = monday.add(const Duration(days: 6));
    final out = <DueDeposit>[];
    for (final g in list()) {
      if (g.vaultAccountId == null) continue;
      // 建目标的那一周和它前一周照结（原来就是：周一建目标，上周的零头照样存进去）；更早的周不倒补——
      // 补结扩成最近 4 周以后，不加这条新目标一建就会一次倒存 4 周的零头
      final created = DateTime.fromMillisecondsSinceEpoch(g.createdAt);
      if (DateTime.utc(created.year, created.month, created.day).isAfter(sunday.add(const Duration(days: 7)))) continue;
      for (final r in g.rules) {
        if (r.kind != GoalRuleKind.roundup || r.roundTo <= 1) continue;
        final fp = 'goal:${g.id}:roundup:$weekMonday';
        if (ledger.hasFingerprint(fp)) continue;
        var sum = 0;
        for (final tx in ledger.listTransactions(from: monday.subtract(const Duration(days: 1)), to: sunday.add(const Duration(days: 2)), type: TransactionType.expense, limit: 1 << 30)) {
          final d = tx.occurredAt.localDate;
          if (d.compareTo(weekMonday) < 0 || d.compareTo(_fmt(sunday)) > 0) continue;
          if (tx.currency != g.currency || tx.accountId == g.vaultAccountId) continue;
          final rem = tx.amountMinor % r.roundTo;
          if (rem > 0) sum += r.roundTo - rem;
        }
        if (sum > 0) out.add(DueDeposit(goal: g, rule: r, amountMinor: sum, fingerprint: fp, note: '「${g.name}」零头周结'));
      }
    }
    return out;
  }

  static DateTime _parse(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// [Goals.remove] 的结果：锁仓账户是真删了（没记录）还是归档了（有 [postingCount] 条记录）。
class GoalRemoval {
  final bool vaultDeleted;
  final int postingCount;
  const GoalRemoval({required this.vaultDeleted, required this.postingCount});
}
