import 'dart:convert';

import 'db/database.dart';
import 'errors.dart';
import 'ids.dart';
import 'models/account.dart';
import 'models/audit.dart';
import 'models/category.dart';
import 'models/draft.dart';
import 'models/enums.dart';
import 'models/transaction.dart';
import 'achievements.dart';
import 'budget.dart';
import 'changes.dart';
import 'cards.dart';
import 'debts.dart';
import 'goals.dart';
import 'memory.dart';
import 'profile.dart';
import 'recurring.dart';
import 'tasks.dart';
import 'occurred_at.dart';
import 'money.dart';
import 'validation.dart';

/// 账本门面（§18.1）。上层（UI / Interpreter / MCP）只通过这里读写账本。
/// 写路径永远是 propose → commit；没有任何绕过草稿直接写交易的入口。
class Ledger implements ValidationContext {
  final LedgerDatabase _db;
  final DateTime Function() _clock;

  late final ChangeLog changes = ChangeLog(_db, _nowMs);
  late final MemoryStore memory = MemoryStore(_db, _nowMs, changes);
  late final RecurringStore recurring = RecurringStore(this, _db, _nowMs, changes);
  late final BudgetStore budgets = BudgetStore(this, _db, _nowMs, changes);
  late final GoalStore goals = GoalStore(this, _db, _nowMs, changes);
  late final TaskStore tasks = TaskStore(this, _db, _nowMs, changes);
  late final AchievementStore achievements = AchievementStore(this, _db, _nowMs, changes);
  late final ProfileStore profile = ProfileStore(_db, _nowMs, changes);
  late final Debts debts = Debts(this);
  late final CreditCards cards = CreditCards(this);

  Ledger(this._db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// 底层连接（备份 VACUUM INTO 等需要）。上层不要拿它写业务表。
  LedgerDatabase get database => _db;

  @override
  DateTime now() => _clock();

  int _nowMs() => now().toUtc().millisecondsSinceEpoch;

  // ---------------------------------------------------------------- accounts

  Account createAccount({
    required String name,
    required AccountType type,
    required String currency,
    int initialBalanceMinor = 0,
    String? institution,
    String? icon,
    int sortOrder = 0,
    String? id,
  }) {
    if (!Currency.isKnown(currency)) {
      throw ValidationException('currency', 'unknown currency $currency');
    }
    if (name.trim().isEmpty) throw ValidationException('name', 'required');
    final aid = id ?? Ulid.next();
    final ts = _nowMs();
    return _db.transaction(() {
      _db.execute(
        'INSERT INTO accounts(id,name,type,currency,initial_balance_minor,institution,icon,is_archived,sort_order,created_at,updated_at) '
        'VALUES (?,?,?,?,?,?,?,0,?,?,?)',
        [aid, name.trim(), type.db, currency, initialBalanceMinor, institution, icon, sortOrder, ts, ts],
      );
      final a = getAccount(aid);
      _audit(Actor.user, 'account.create', 'account', aid, after: a.toJson(), confirmed: true);
      changes.record('account', aid, a.toJson());
      return a;
    });
  }

  @override
  Account? account(String id) {
    final rows = _db.select('SELECT * FROM accounts WHERE id = ?', [id]);
    return rows.isEmpty ? null : Account.fromRow(rows.first);
  }

  Account getAccount(String id) => account(id) ?? (throw NotFoundException('account', id));

  /// 锁仓（vault）账户默认不列：它们属于目标页，账户页 / 选择器 / 模型上下文都不该看见；算净资产时 [includeVault]。
  List<Account> listAccounts({bool includeArchived = false, bool includeVault = false}) => _db
      .select('SELECT * FROM accounts ${includeArchived ? '' : 'WHERE is_archived = 0'} ORDER BY sort_order, created_at')
      .map(Account.fromRow)
      .where((a) => includeVault || a.type != AccountType.vault)
      .toList();

  void archiveAccount(String id) {
    final before = getAccount(id);
    if (before.isArchived) throw InvalidStateException('account already archived');
    _db.transaction(() {
      _db.execute('UPDATE accounts SET is_archived = 1, updated_at = ? WHERE id = ?', [_nowMs(), id]);
      _audit(Actor.user, 'account.archive', 'account', id,
          before: before.toJson(), after: getAccount(id).toJson(), confirmed: true);
      changes.record('account', id, getAccount(id).toJson());
    });
  }

  void unarchiveAccount(String id) {
    final before = getAccount(id);
    if (!before.isArchived) throw InvalidStateException('account is not archived');
    _db.transaction(() {
      _db.execute('UPDATE accounts SET is_archived = 0, updated_at = ? WHERE id = ?', [_nowMs(), id]);
      _audit(Actor.user, 'account.unarchive', 'account', id, before: before.toJson(), after: getAccount(id).toJson(), confirmed: true);
      changes.record('account', id, getAccount(id).toJson());
    });
  }

  /// 这个账户有几条 posting（含作废交易的）——有就不能删，只能归档。
  int accountPostingCount(String id) => _db.select('SELECT COUNT(*) AS n FROM postings WHERE account_id = ?', [id]).first['n'] as int;

  /// 删账户：只允许删「没有任何交易记录」的账户（有记录就删不了——历史对不上，用 [archiveAccount]）。
  /// 目标 / 周期项还引用着它也拒绝（调用方先清引用，见 Debts.remove）；记忆里的默认账户和发薪账户会自动清掉。
  void deleteAccount(String id) {
    final a = getAccount(id);
    final n = accountPostingCount(id);
    if (n > 0) throw InvalidStateException('account has $n postings; archive it instead');
    final refs = <String>[];
    if ((_db.select('SELECT COUNT(*) AS n FROM goals WHERE vault_account_id = ? OR linked_account_id = ?', [id, id]).first['n'] as int) > 0) refs.add('goals');
    if ((_db.select("SELECT COUNT(*) AS n FROM recurring WHERE template LIKE '%' || ? || '%'", [id]).first['n'] as int) > 0) refs.add('recurring');
    if ((_db.select("SELECT COUNT(*) AS n FROM drafts WHERE status = 'pending' AND payload LIKE '%' || ? || '%'", [id]).first['n'] as int) > 0) refs.add('drafts');
    if (refs.isNotEmpty) throw InvalidStateException('account in use by ${refs.join(', ')}');
    _db.transaction(() {
      _db.execute('UPDATE memory_map SET account_id = NULL WHERE account_id = ?', [id]);
      if (profile.salaryAccountId == id) profile.salaryAccountId = null;
      if (profile.defaultAccountId == id) profile.defaultAccountId = null;
      if (profile.getString('${CreditCards.keyPrefix}$id') != null) profile.set('${CreditCards.keyPrefix}$id', null); // 信用卡条款跟着账户走
      _db.execute('DELETE FROM accounts WHERE id = ?', [id]);
      _audit(Actor.user, 'account.delete', 'account', id, before: a.toJson(), confirmed: true);
      changes.record('account', id, null, deleted: true);
    });
  }

  /// 改账户。币种只有在没有任何 posting 时才能改（否则历史交易币种对不上）。
  Account updateAccount(String id, {String? name, AccountType? type, String? currency, int? initialBalanceMinor, String? institution, String? icon, int? sortOrder}) {
    final before = getAccount(id);
    if (name != null && name.trim().isEmpty) throw ValidationException('name', 'required');
    if (currency != null && currency != before.currency) {
      if (!Currency.isKnown(currency)) throw ValidationException('currency', 'unknown currency $currency');
      final used = _db.select('SELECT COUNT(*) AS n FROM postings WHERE account_id = ?', [id]).first['n'] as int;
      if (used > 0) throw InvalidStateException('account has $used postings; currency cannot change');
    }
    return _db.transaction(() {
      _db.execute(
        'UPDATE accounts SET name=?, type=?, currency=?, initial_balance_minor=?, institution=?, icon=?, sort_order=?, updated_at=? WHERE id=?',
        [
          name?.trim() ?? before.name, (type ?? before.type).db, currency ?? before.currency, initialBalanceMinor ?? before.initialBalanceMinor,
          institution ?? before.institution, icon ?? before.icon, sortOrder ?? before.sortOrder, _nowMs(), id,
        ],
      );
      final after = getAccount(id);
      _audit(Actor.user, 'account.update', 'account', id, before: before.toJson(), after: after.toJson(), confirmed: true);
      changes.record('account', id, after.toJson());
      return after;
    });
  }

  /// 余额不落库：initial + Σ 已确认交易的 posting（§5.2）。
  Money balance(String accountId) {
    final a = getAccount(accountId);
    final r = _db.select(
      'SELECT COALESCE(SUM(p.amount_minor),0) AS s FROM postings p '
      'JOIN transactions t ON t.id = p.transaction_id '
      "WHERE p.account_id = ? AND t.status = 'confirmed'",
      [accountId],
    ).first;
    return Money(a.initialBalanceMinor + (r['s'] as int), a.currency);
  }

  Map<String, Money> balances({bool includeArchived = false, bool includeVault = false}) =>
      {for (final a in listAccounts(includeArchived: includeArchived, includeVault: includeVault)) a.id: balance(a.id)};

  // -------------------------------------------------------------- categories

  void seedDefaultCategories() {
    _db.transaction(() {
      for (final c in defaultCategories) {
        final existing = category(c.id);
        if (existing != null) {
          // 老库里种的默认分类没有图标：补上（用户改过的不动）
          if (existing.icon == null && c.icon != null) _db.execute('UPDATE categories SET icon = ? WHERE id = ? AND icon IS NULL', [c.icon, c.id]);
          continue;
        }
        _db.execute(
          'INSERT INTO categories(id,parent_id,kind,name,icon,is_default,sort_order) VALUES (?,?,?,?,?,1,?)',
          [c.id, c.parentId, c.kind.db, c.name, c.icon, c.sortOrder],
        );
        // 默认分类每台设备都会种，不记变更（否则两台设备互相推同一批）
      }
    });
  }

  Category createCategory({
    required String name,
    required CategoryKind kind,
    String? parentId,
    String? icon,
    int sortOrder = 0,
    String? id,
  }) {
    if (name.trim().isEmpty) throw ValidationException('name', 'required');
    if (parentId != null) {
      final p = category(parentId) ?? (throw NotFoundException('category', parentId));
      if (p.kind != kind) throw ValidationException('parent_id', 'parent kind mismatch');
    }
    final cid = id ?? Ulid.next();
    return _db.transaction(() {
      _db.execute(
        'INSERT INTO categories(id,parent_id,kind,name,icon,is_default,sort_order) VALUES (?,?,?,?,?,0,?)',
        [cid, parentId, kind.db, name.trim(), icon, sortOrder],
      );
      final c = category(cid)!;
      _audit(Actor.user, 'category.create', 'category', cid, after: c.toJson(), confirmed: true);
      changes.record('category', cid, c.toJson());
      return c;
    });
  }

  /// 改分类：名字 / 父级 / 图标 / 排序。父级不能是自己或自己的子孙，且同 kind。
  Category updateCategory(String id, {String? name, String? parentId, bool clearParent = false, String? icon, int? sortOrder}) {
    final before = category(id) ?? (throw NotFoundException('category', id));
    if (name != null && name.trim().isEmpty) throw ValidationException('name', 'required');
    String? newParent = clearParent ? null : (parentId ?? before.parentId);
    if (newParent != null) {
      if (newParent == id) throw ValidationException('parent_id', 'cannot be itself');
      final p = category(newParent) ?? (throw NotFoundException('category', newParent));
      if (p.kind != before.kind) throw ValidationException('parent_id', 'parent kind mismatch');
      var cur = p.parentId;
      while (cur != null) {
        if (cur == id) throw ValidationException('parent_id', 'cannot move under own descendant');
        cur = category(cur)?.parentId;
      }
    }
    return _db.transaction(() {
      _db.execute('UPDATE categories SET name=?, parent_id=?, icon=?, sort_order=? WHERE id=?',
          [name?.trim() ?? before.name, newParent, icon ?? before.icon, sortOrder ?? before.sortOrder, id]);
      final after = category(id)!;
      _audit(Actor.user, 'category.update', 'category', id, before: before.toJson(), after: after.toJson(), confirmed: true);
      changes.record('category', id, after.toJson());
      return after;
    });
  }

  /// 删分类：被交易 / 子分类 / 预算 / 周期 / 记忆引用时拒绝，并说明是谁在用。
  void deleteCategory(String id) {
    final c = category(id) ?? (throw NotFoundException('category', id));
    if (c.isDefault) throw InvalidStateException('default categories cannot be deleted');
    final refs = <String>[];
    int n(String sql) => _db.select(sql, [id]).first['n'] as int;
    if (n('SELECT COUNT(*) AS n FROM transactions WHERE category_id = ?') > 0) refs.add('transactions');
    if (n('SELECT COUNT(*) AS n FROM categories WHERE parent_id = ?') > 0) refs.add('subcategories');
    if (n('SELECT COUNT(*) AS n FROM budgets WHERE category_id = ?') > 0) refs.add('budgets');
    if (n('SELECT COUNT(*) AS n FROM memory_map WHERE category_id = ?') > 0) refs.add('memory');
    if (n("SELECT COUNT(*) AS n FROM recurring WHERE template LIKE '%' || ? || '%'") > 0) refs.add('recurring');
    if (refs.isNotEmpty) throw InvalidStateException('category in use by ${refs.join(', ')}');
    _db.transaction(() {
      _db.execute('DELETE FROM categories WHERE id = ?', [id]);
      _audit(Actor.user, 'category.delete', 'category', id, before: c.toJson(), confirmed: true);
      changes.record('category', id, null, deleted: true);
    });
  }

  @override
  Category? category(String id) {
    final rows = _db.select('SELECT * FROM categories WHERE id = ?', [id]);
    return rows.isEmpty ? null : Category.fromRow(rows.first);
  }

  List<Category> listCategories({CategoryKind? kind}) => _db
      .select(
        'SELECT * FROM categories ${kind == null ? '' : 'WHERE kind = ?'} ORDER BY sort_order, name',
        kind == null ? const [] : [kind.db],
      )
      .map(Category.fromRow)
      .toList();

  // ------------------------------------------------------------------ drafts

  /// 提议若干候选（§5.4）。返回实际建立的 Draft（精确指纹重复的被丢弃，不在返回里）。
  List<Draft> propose(
    List<DraftInput> inputs, {
    required Source source,
    Actor actor = Actor.interpreter,
    String? sessionId,
    String? interpreter,
    String? modelUsed,
    String? groupId,
  }) {
    if (inputs.isEmpty) return const [];
    final gid = groupId ?? Ulid.next();
    return _db.transaction(() {
      final out = <Draft>[];
      for (final input in inputs) {
        String? dupOf;
        if (input.eventFingerprint != null) {
          final hit = _findByFingerprint(input.eventFingerprint!);
          if (hit != null) {
            if (input.fingerprintIsExact) {
              _audit(actor, 'draft.dedupe', 'event', input.eventFingerprint!,
                  after: {'duplicate_of': hit, 'payload': input.payload}, interpreter: interpreter, modelUsed: modelUsed);
              continue;
            }
            dupOf = hit;
          }
        }
        // 跨来源疑似重复：同一笔钱常被通知、支付页识别、截图、账单导入各抓一次，它们的指纹格式各不相同，
        // 只比指纹永远撞不上。自动来源的新建草稿再按「方向 + 金额 + 币种 + 前后 10 分钟」找一遍已记的账和待确认的草稿。
        if (dupOf == null && input.kind == DraftKind.create && _dupCheckedSources.contains(source)) {
          dupOf = _findNearDuplicate(input.payload, excludeGroup: gid);
        }
        final missing = _draftProblems(input);
        final did = Ulid.next();
        _db.execute(
          'INSERT INTO drafts(id,group_id,kind,target_transaction_id,source,session_id,event_fingerprint,possible_duplicate_of,'
          'payload,interpreter,model_used,confidence,missing_fields,status,created_at) '
          "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',?)",
          [
            did, gid, input.kind.db, input.targetTransactionId, source.db, sessionId, input.eventFingerprint, dupOf,
            jsonEncode(input.payload), interpreter, modelUsed, input.confidence, jsonEncode(missing), _nowMs(),
          ],
        );
        final d = getDraft(did);
        _audit(actor, 'draft.propose', 'draft', did,
            after: d.toJson(), draftId: did, interpreter: interpreter, modelUsed: modelUsed);
        out.add(d);
      }
      return out;
    });
  }

  static const _dupCheckedSources = {Source.notification, Source.screenshot, Source.share, Source.import_};
  static const nearDuplicateWindow = Duration(minutes: 10);

  /// 金额、方向、币种都一样，发生时间前后 [nearDuplicateWindow] 内的已确认交易（优先）或待确认草稿 id；没有返回 null。
  String? _findNearDuplicate(Map<String, Object?> p, {String? excludeGroup}) {
    final type = p['type'];
    final amount = p['amount_minor'];
    final currency = p['currency'];
    final at = p['occurred_at'];
    if (type is! String || amount is! int || amount <= 0 || currency is! String || at is! String) return null;
    final OccurredAt when;
    try {
      when = OccurredAt.parse(at);
    } on FormatException {
      return null;
    }
    final w = nearDuplicateWindow.inMilliseconds;
    final t = _db.select(
      "SELECT t.id FROM transactions t WHERE t.status = 'confirmed' AND t.type = ? AND t.currency = ? AND t.occurred_at_ms BETWEEN ? AND ? "
      'AND EXISTS (SELECT 1 FROM postings p WHERE p.transaction_id = t.id AND ABS(p.amount_minor) = ?) ORDER BY ABS(t.occurred_at_ms - ?) LIMIT 1',
      [type, currency, when.millis - w, when.millis + w, amount, when.millis],
    );
    if (t.isNotEmpty) return t.first['id'] as String;
    // 待确认草稿：只看最近两天建的（收件箱里一般不会压更久），在 Dart 里比 payload
    final since = _nowMs() - const Duration(days: 2).inMilliseconds;
    for (final r in _db.select("SELECT id, group_id, payload FROM drafts WHERE status = 'pending' AND kind = 'create' AND created_at >= ?", [since])) {
      if (excludeGroup != null && r['group_id'] == excludeGroup) continue;
      final q = (jsonDecode(r['payload'] as String) as Map).cast<String, Object?>();
      if (q['type'] != type || q['amount_minor'] != amount || q['currency'] != currency || q['occurred_at'] is! String) continue;
      try {
        if ((OccurredAt.parse(q['occurred_at'] as String).millis - when.millis).abs() <= w) return r['id'] as String;
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  /// 某指纹是否已有已确认交易或待处理草稿（目标的定存 / 零头周结用它防重）。
  bool hasFingerprint(String fp) => _findByFingerprint(fp) != null;

  String? _findByFingerprint(String fp) {
    final t = _db.select(
        "SELECT id FROM transactions WHERE event_fingerprint = ? AND status = 'confirmed' LIMIT 1", [fp]);
    if (t.isNotEmpty) return t.first['id'] as String;
    final d = _db.select(
        "SELECT id FROM drafts WHERE event_fingerprint = ? AND status IN ('pending','committed') LIMIT 1", [fp]);
    return d.isEmpty ? null : d.first['id'] as String;
  }

  List<String> _draftProblems(DraftInput input) {
    switch (input.kind) {
      case DraftKind.create:
        return analyzeCreatePayload(input.payload, this).problemFields;
      case DraftKind.update:
        final t = input.targetTransactionId == null ? null : transaction(input.targetTransactionId!);
        if (t == null) return ['target_transaction_id'];
        final merged = {...t.toPayload(), ...input.payload};
        return analyzeCreatePayload(merged, this, selfId: t.id).problemFields;
      case DraftKind.void_:
        final t = input.targetTransactionId == null ? null : transaction(input.targetTransactionId!);
        final out = <String>[];
        if (t == null) out.add('target_transaction_id');
        if ((input.payload['reason'] as String?)?.trim().isEmpty ?? true) out.add('reason');
        return out;
    }
  }

  Draft getDraft(String id) {
    final rows = _db.select('SELECT * FROM drafts WHERE id = ?', [id]);
    if (rows.isEmpty) throw NotFoundException('draft', id);
    return Draft.fromRow(rows.first);
  }

  List<Draft> listDrafts({DraftStatus? status, String? groupId, int limit = 200}) {
    final where = <String>[];
    final params = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      params.add(status.db);
    }
    if (groupId != null) {
      where.add('group_id = ?');
      params.add(groupId);
    }
    final sql = 'SELECT * FROM drafts ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
        'ORDER BY created_at DESC LIMIT ?';
    return _db.select(sql, [...params, limit]).map(Draft.fromRow).toList();
  }

  /// 用户确认一条草稿。幂等：已提交的再次调用返回同一笔交易。
  /// [edits] 是用户在收件箱里改过的字段，覆盖草稿 payload 后再整体校验。
  Transaction commit(String draftId, {Map<String, Object?>? edits}) {
    return _db.transaction(() {
      final d = getDraft(draftId);
      if (d.status == DraftStatus.committed) return getTransaction(d.committedTransactionId!);
      if (d.status == DraftStatus.dismissed) throw InvalidStateException('draft $draftId was dismissed');

      // 多设备：周期账单 / 定存 / 任务奖励这类按日子算出来的指纹，每台设备都会各自起草一份（草稿不同步）。
      // 另一台已经确认、交易同步过来了，这边再确认就是重复——直接认领那笔，不再落第二次账。
      final fp = d.eventFingerprint;
      if (d.kind == DraftKind.create && fp != null && _deterministicFp.hasMatch(fp)) {
        final existing = _db.select("SELECT id FROM transactions WHERE event_fingerprint = ? AND status = 'confirmed' LIMIT 1", [fp]);
        if (existing.isNotEmpty) {
          final txId = existing.first['id'] as String;
          _db.execute("UPDATE drafts SET status = 'committed', committed_transaction_id = ?, resolved_at = ? WHERE id = ?", [txId, _nowMs(), draftId]);
          _audit(Actor.user, 'draft.commit_existing', 'draft', draftId, after: {'transaction_id': txId, 'fingerprint': fp}, draftId: draftId, confirmed: true);
          return getTransaction(txId);
        }
      }
      final finalPayload = {...d.payload, ...?edits};
      final Transaction tx;
      switch (d.kind) {
        case DraftKind.create:
          tx = _createTransaction(finalPayload, d);
          if (tx.type == TransactionType.expense || tx.type == TransactionType.income) {
            memory.learn(
              merchant: tx.merchant,
              description: tx.description,
              categoryId: tx.categoryId,
              accountId: tx.accountId,
              categoryCorrected: edits?.containsKey('category_id') == true && edits!['category_id'] != d.payload['category_id'],
              accountCorrected: edits?.containsKey('account_id') == true && edits!['account_id'] != d.payload['account_id'],
            );
          }
        case DraftKind.update:
          tx = _updateTransaction(d.targetTransactionId!, finalPayload, d);
          if ((tx.type == TransactionType.expense || tx.type == TransactionType.income) && (finalPayload.containsKey('category_id') || finalPayload.containsKey('account_id'))) {
            memory.learn(
              merchant: tx.merchant,
              description: tx.description,
              categoryId: tx.categoryId,
              accountId: tx.accountId,
              categoryCorrected: finalPayload.containsKey('category_id'),
              accountCorrected: finalPayload.containsKey('account_id'),
            );
          }
        case DraftKind.void_:
          tx = _voidTransaction(d.targetTransactionId!, (finalPayload['reason'] as String?) ?? '', d);
      }
      _db.execute(
        "UPDATE drafts SET status = 'committed', committed_transaction_id = ?, resolved_at = ?, payload = ?, missing_fields = '[]' WHERE id = ?",
        [tx.id, _nowMs(), jsonEncode(finalPayload), draftId],
      );
      _audit(Actor.user, 'draft.commit', 'draft', draftId,
          before: d.payload, after: finalPayload, draftId: draftId,
          interpreter: d.interpreter, modelUsed: d.modelUsed, confirmed: true);
      return tx;
    });
  }

  static final _deterministicFp = RegExp(r'^(recurring|goal|task):');

  /// 整组确认（多笔解析）。任一条失败整组回滚，不留半截。
  List<Transaction> commitGroup(String groupId) => _db.transaction(() {
        final drafts = listDrafts(groupId: groupId)..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (drafts.isEmpty) throw NotFoundException('draft group', groupId);
        return [for (final d in drafts.where((d) => d.status != DraftStatus.dismissed)) commit(d.id)];
      });

  void dismiss(String draftId) {
    _db.transaction(() {
      final d = getDraft(draftId);
      if (d.status != DraftStatus.pending) throw InvalidStateException('draft is ${d.status.db}');
      _db.execute("UPDATE drafts SET status = 'dismissed', resolved_at = ? WHERE id = ?", [_nowMs(), draftId]);
      _audit(Actor.user, 'draft.dismiss', 'draft', draftId, before: d.toJson(), draftId: draftId, confirmed: true);
    });
  }

  // ------------------------------------------------------------ transactions

  Transaction _createTransaction(Map<String, Object?> payload, Draft d) {
    final a = analyzeCreatePayload(payload, this)..throwIfInvalid();
    final v = a.validated!;
    final id = Ulid.next();
    final ts = _nowMs();
    _db.execute(
      'INSERT INTO transactions(id,type,occurred_at_ms,tz_offset_min,currency,merchant,description,category_id,tags,source,status,'
      'confidence,refund_of_id,recurring_id,event_fingerprint,metadata,created_at,updated_at) '
      "VALUES (?,?,?,?,?,?,?,?,?,?,'confirmed',?,?,?,?,?,?,?)",
      [
        id, v.type.db, v.occurredAt.millis, v.occurredAt.offsetMinutes, v.currency, v.merchant, v.description,
        v.categoryId, jsonEncode(v.tags), d.source.db, d.confidence, v.refundOfId,
        d.source == Source.recurring && v.metadata['recurring_id'] is String ? v.metadata['recurring_id'] : null, d.eventFingerprint,
        jsonEncode(v.metadata), ts, ts,
      ],
    );
    _insertPostings(id, v);
    final tx = getTransaction(id);
    _audit(Actor.user, 'transaction.create', 'transaction', id,
        after: tx.toJson(), draftId: d.id, interpreter: d.interpreter, modelUsed: d.modelUsed, confirmed: true);
    changes.record('transaction', id, tx.toJson());
    return tx;
  }

  Transaction _updateTransaction(String id, Map<String, Object?> patch, Draft d) {
    final before = getTransaction(id);
    if (before.status != TransactionStatus.confirmed) throw InvalidStateException('transaction $id is void');
    final merged = {...before.toPayload(), ...patch};
    final a = analyzeCreatePayload(merged, this, selfId: id)..throwIfInvalid();
    final v = a.validated!;
    if (v.type != TransactionType.refund && _refundedMinorRaw(id) > 0 && v.type != before.type) {
      throw InvalidStateException('transaction has refunds; void them before changing its type');
    }
    _db.execute(
      'UPDATE transactions SET type=?,occurred_at_ms=?,tz_offset_min=?,currency=?,merchant=?,description=?,category_id=?,'
      'tags=?,refund_of_id=?,metadata=?,updated_at=? WHERE id = ?',
      [
        v.type.db, v.occurredAt.millis, v.occurredAt.offsetMinutes, v.currency, v.merchant, v.description,
        v.categoryId, jsonEncode(v.tags), v.refundOfId, jsonEncode(v.metadata), _nowMs(), id,
      ],
    );
    _db.execute('DELETE FROM postings WHERE transaction_id = ?', [id]);
    _insertPostings(id, v);
    final after = getTransaction(id);
    _audit(Actor.user, 'transaction.update', 'transaction', id,
        before: before.toJson(), after: after.toJson(), draftId: d.id,
        interpreter: d.interpreter, modelUsed: d.modelUsed, confirmed: true);
    changes.record('transaction', id, after.toJson());
    return after;
  }

  Transaction _voidTransaction(String id, String reason, Draft d) {
    final before = getTransaction(id);
    if (before.status != TransactionStatus.confirmed) throw InvalidStateException('transaction $id already void');
    if (reason.trim().isEmpty) throw MissingFieldsException(['reason']);
    if (_refundedMinorRaw(id) > 0) {
      throw InvalidStateException('transaction has confirmed refunds; void them first');
    }
    final meta = {...before.metadata, 'void_reason': reason.trim()};
    _db.execute("UPDATE transactions SET status = 'void', metadata = ?, updated_at = ? WHERE id = ?",
        [jsonEncode(meta), _nowMs(), id]);
    final after = getTransaction(id);
    _audit(Actor.user, 'transaction.void', 'transaction', id,
        before: before.toJson(), after: after.toJson(), draftId: d.id, confirmed: true);
    changes.record('transaction', id, after.toJson());
    return after;
  }

  void _insertPostings(String txId, ValidatedTransaction v) {
    for (final (accountId, amount) in v.postings()) {
      _db.execute('INSERT INTO postings(id,transaction_id,account_id,amount_minor) VALUES (?,?,?,?)',
          [Ulid.next(), txId, accountId, amount]);
    }
  }

  @override
  Transaction? transaction(String id) {
    final rows = _db.select('SELECT * FROM transactions WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return Transaction.fromRow(rows.first, _postingsOf(id));
  }

  Transaction getTransaction(String id) => transaction(id) ?? (throw NotFoundException('transaction', id));

  List<Posting> _postingsOf(String txId) => _db
      .select('SELECT * FROM postings WHERE transaction_id = ? ORDER BY amount_minor', [txId])
      .map(Posting.fromRow)
      .toList();

  @override
  int refundedMinor(String originalId, {String? excludingId}) => _refundedMinorRaw(originalId, excludingId: excludingId);

  int _refundedMinorRaw(String originalId, {String? excludingId}) {
    final r = _db.select(
      'SELECT COALESCE(SUM(p.amount_minor),0) AS s FROM transactions t JOIN postings p ON p.transaction_id = t.id '
      "WHERE t.refund_of_id = ? AND t.status = 'confirmed' AND t.id != ?",
      [originalId, excludingId ?? ''],
    ).first;
    return r['s'] as int;
  }

  /// 猜一笔退款退的是哪一笔支出：近 [days] 天、同币种、还没退完的支出里，
  /// 商户对得上的优先（取最近），其次「剩余可退金额正好等于这笔」且只有一笔的；都没把握返回 null（留给用户在收件箱里挑）。
  String? guessRefundOriginal({required int amountMinor, required String currency, String? merchant, DateTime? at, int days = 90}) {
    final when = at ?? now();
    final cands = [
      for (final t in listTransactions(type: TransactionType.expense, from: when.subtract(Duration(days: days)), to: when.add(const Duration(days: 1)), limit: 2000))
        if (t.currency == currency && t.amountMinor - refundedMinor(t.id) >= amountMinor) t,
    ];
    final m = merchant?.trim();
    if (m != null && m.isNotEmpty) {
      for (final t in cands) {
        final tm = '${t.merchant ?? ''} ${t.description ?? ''}';
        if (tm.contains(m) || (t.merchant != null && t.merchant!.isNotEmpty && m.contains(t.merchant!))) return t.id;
      }
    }
    final exact = cands.where((t) => t.amountMinor - refundedMinor(t.id) == amountMinor).toList();
    return exact.length == 1 ? exact.single.id : null;
  }

  List<Transaction> listTransactions({
    DateTime? from,
    DateTime? to,
    String? accountId,
    String? categoryId,
    TransactionType? type,
    TransactionStatus status = TransactionStatus.confirmed,
    int limit = 500,
  }) {
    final where = <String>['t.status = ?'];
    final params = <Object?>[status.db];
    if (from != null) {
      where.add('t.occurred_at_ms >= ?');
      params.add(from.toUtc().millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('t.occurred_at_ms < ?');
      params.add(to.toUtc().millisecondsSinceEpoch);
    }
    if (categoryId != null) {
      where.add('t.category_id = ?');
      params.add(categoryId);
    }
    if (type != null) {
      where.add('t.type = ?');
      params.add(type.db);
    }
    if (accountId != null) {
      where.add('EXISTS (SELECT 1 FROM postings p WHERE p.transaction_id = t.id AND p.account_id = ?)');
      params.add(accountId);
    }
    final rows = _db.select(
      'SELECT t.* FROM transactions t WHERE ${where.join(' AND ')} ORDER BY t.occurred_at_ms DESC, t.created_at DESC LIMIT ?',
      [...params, limit],
    );
    // postings 一次成批取，别每笔再查一次（N+1：几千笔就是几千条 SQL，在 UI 线程上直接掉帧）
    final postings = _postingsOfAll([for (final r in rows) r['id'] as String]);
    return [for (final r in rows) Transaction.fromRow(r, postings[r['id'] as String] ?? const [])];
  }

  /// 只数笔数，不实例化（更多页 / 数据页 / 同步页显示「N 笔记录」用）。
  int countTransactions({TransactionStatus status = TransactionStatus.confirmed}) =>
      _db.select('SELECT COUNT(*) AS n FROM transactions WHERE status = ?', [status.db]).first['n'] as int;

  /// 最早一笔记录的入库时间（毫秒）；空账本 = null。用作「用了多久」的依据：跟着账本走，换机 / 重装恢复后不会归零。
  /// [from] 之后有已确认记录的本地日期（yyyy-MM-dd）。只读时间两列，不实例化交易和 posting（连续记账天数这类判定用）。
  Set<String> recordedDates({required DateTime from}) {
    final out = <String>{};
    for (final r in _db.select("SELECT occurred_at_ms, tz_offset_min FROM transactions WHERE status = 'confirmed' AND occurred_at_ms >= ?", [from.toUtc().millisecondsSinceEpoch])) {
      out.add(OccurredAt.fromMillis(r['occurred_at_ms'] as int, r['tz_offset_min'] as int).localDate);
    }
    return out;
  }

  /// 最早一笔已确认交易的发生时间（毫秒）；空账本 = null。「上个月的储蓄率」这类成就要求那个月整月都在记账。
  int? firstOccurredAtMs() {
    final r = _db.select("SELECT MIN(occurred_at_ms) AS t FROM transactions WHERE status = 'confirmed'");
    return r.isEmpty ? null : r.first['t'] as int?;
  }

  int? firstRecordedAtMs() {
    final r = _db.select('SELECT MIN(created_at) AS t FROM transactions');
    return r.isEmpty ? null : r.first['t'] as int?;
  }

  Map<String, List<Posting>> _postingsOfAll(List<String> txIds) {
    final out = <String, List<Posting>>{};
    const chunk = 500; // SQLite 绑定变量上限之内
    for (var i = 0; i < txIds.length; i += chunk) {
      final ids = txIds.sublist(i, i + chunk > txIds.length ? txIds.length : i + chunk);
      final rows = _db.select(
        'SELECT * FROM postings WHERE transaction_id IN (${List.filled(ids.length, '?').join(',')}) ORDER BY amount_minor',
        ids,
      );
      for (final r in rows) {
        (out[r['transaction_id'] as String] ??= []).add(Posting.fromRow(r));
      }
    }
    return out;
  }

  // ----------------------------------------------------------------- restore

  /// 整库替换（备份恢复用）。一个事务：清空 → 写入；任何一条非法整体回滚。返回交易数。
  int restoreRaw({
    required List<Map<String, Object?>> accounts,
    required List<Map<String, Object?>> categories,
    required List<Map<String, Object?>> transactions,
    required List<Map<String, Object?>> memory,
    List<Map<String, Object?>> recurring = const [],
    List<Map<String, Object?>> budgets = const [],
    List<Map<String, Object?>> goals = const [],
    List<Map<String, Object?>> tasks = const [],
    List<Map<String, Object?>> achievements = const [],
    Map<String, String> profile = const {},
  }) {
    return _db.transaction(() {
      for (final t in ['postings', 'transactions', 'drafts', 'events', 'memory_map', 'budgets', 'recurring', 'goals', 'tasks', 'achievements', 'profile', 'categories', 'accounts', 'changes']) {
        _db.execute('DELETE FROM $t');
      }
      final ts = _nowMs();
      for (final c in categories) {
        _db.execute('INSERT INTO categories(id,parent_id,kind,name,icon,is_default,sort_order) VALUES (?,?,?,?,?,?,?)',
            [c['id'], c['parent_id'], c['kind'], c['name'], c['icon'], c['is_default'] == true ? 1 : 0, c['sort_order'] ?? 0]);
      }
      for (final a in accounts) {
        _db.execute(
          'INSERT INTO accounts(id,name,type,currency,initial_balance_minor,institution,icon,is_archived,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
          [a['id'], a['name'], a['type'], a['currency'], a['initial_balance_minor'] ?? 0, a['institution'], a['icon'], a['is_archived'] == true ? 1 : 0, a['sort_order'] ?? 0, ts, ts],
        );
      }
      var n = 0;
      for (final t in transactions) {
        final occ = OccurredAt.parse(t['occurred_at'] as String);
        final postings = (t['postings'] as List).cast<Map>();
        if (postings.isEmpty) throw ValidationException('postings', 'transaction ${t['id']} has no postings');
        _db.execute(
          'INSERT INTO transactions(id,type,occurred_at_ms,tz_offset_min,currency,merchant,description,category_id,tags,source,status,'
          'confidence,refund_of_id,recurring_id,event_fingerprint,metadata,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [
            t['id'], t['type'], occ.millis, occ.offsetMinutes, t['currency'], t['merchant'], t['description'], t['category_id'],
            jsonEncode(t['tags'] ?? const []), t['source'] ?? 'import', t['status'] ?? 'confirmed', t['confidence'], t['refund_of_id'],
            t['recurring_id'], t['event_fingerprint'], jsonEncode(t['metadata'] ?? const {}),
            _parseIsoMs(t['created_at']) ?? ts, _parseIsoMs(t['updated_at']) ?? ts,
          ],
        );
        for (final p in postings) {
          _db.execute('INSERT INTO postings(id,transaction_id,account_id,amount_minor) VALUES (?,?,?,?)',
              [p['id'] ?? Ulid.next(), t['id'], p['account_id'], p['amount_minor']]);
        }
        n++;
      }
      for (final m in memory) {
        _db.execute('INSERT OR REPLACE INTO memory_map(key,kind,category_id,account_id,hits,corrections,source,updated_at) VALUES (?,?,?,?,?,?,?,?)',
            [m['key'], m['kind'], m['category_id'], m['account_id'], m['hits'] ?? 1, m['corrections'] ?? 0, m['source'] ?? 'confirmed', ts]);
      }
      for (final r in recurring) {
        _db.execute(
          'INSERT INTO recurring(id,name,template,frequency,interval,next_due,reminder_days_before,auto_create,is_active,last_generated,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
          [r['id'], r['name'], jsonEncode(r['template'] ?? const {}), r['frequency'], r['interval'] ?? 1, r['next_due'], r['reminder_days_before'] ?? 0, r['auto_create'] == false ? 0 : 1, r['is_active'] == false ? 0 : 1, r['last_generated'], ts, ts],
        );
      }
      for (final b in budgets) {
        _db.execute(
          'INSERT INTO budgets(id,name,category_id,amount_minor,currency,period,start_date,end_date,alert_threshold,is_active,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
          [b['id'], b['name'], b['category_id'], b['amount_minor'], b['currency'], b['period'], b['start_date'], b['end_date'], b['alert_threshold'] ?? 0.8, b['is_active'] == false ? 0 : 1, ts, ts],
        );
      }
      _audit(Actor.user, 'ledger.restore', 'ledger', 'all', after: {'transactions': n, 'accounts': accounts.length}, confirmed: true);
      final problems = integrityCheck();
      if (problems.isNotEmpty) throw ValidationException('integrity', problems.first);
      for (final g in goals) {
        this.goals.upsertRaw(g);
      }
      for (final t in tasks) {
        this.tasks.upsertRaw(t);
      }
      for (final a in achievements) {
        this.achievements.upsertRaw(a);
      }
      profile.forEach((k, v) => this.profile.upsertRaw({'key': k, 'value': v}));
      recordFullSnapshotAsChanges();
      return n;
    });
  }


  /// 把整本账本当前的每个实体都记成一条本机新变更（时间 = 现在）。整库恢复后调用：
  /// 下次同步整体推上去，其他设备跟着变；拉回来的服务端旧变更按 LWW 比这些旧，全部跳过，不会把刚恢复的内容盖回去。
  void recordFullSnapshotAsChanges() {
    _db.transaction(() {
      for (final a in listAccounts(includeArchived: true, includeVault: true)) {
        changes.record('account', a.id, a.toJson());
      }
      for (final c in listCategories()) {
        if (!c.isDefault) changes.record('category', c.id, c.toJson());
      }
      for (final st in [TransactionStatus.confirmed, TransactionStatus.void_]) {
        for (final t in listTransactions(status: st, limit: 1 << 30)) {
          changes.record('transaction', t.id, t.toJson());
        }
      }
      for (final m in memory.all(limit: 1 << 30)) {
        changes.record('memory', m.key, {'key': m.key, 'kind': m.kind, 'category_id': m.categoryId, 'account_id': m.accountId, 'hits': m.hits, 'corrections': m.corrections, 'source': m.source});
      }
      for (final r in recurring.list(activeOnly: false)) {
        changes.record('recurring', r.id, r.toJson());
      }
      for (final b in budgets.list(activeOnly: false)) {
        changes.record('budget', b.id, BudgetStore.toJson(b));
      }
      for (final g in goals.list(activeOnly: false)) {
        changes.record('goal', g.id, g.toJson());
      }
      for (final t in tasks.list(limit: 1 << 30)) {
        changes.record('task', t.id, t.toJson());
      }
      for (final a in achievements.list()) {
        changes.record('achievement', a.key, a.toJson());
      }
      profile.all().forEach((k, v) => changes.record('profile', k, {'key': k, 'value': v}));
    });
  }

  // -------------------------------------------------------------------- sync

  /// 应用一条来自其他设备的变更。LWW：本地对同一实体有更晚的变更就跳过并审计。
  /// 返回 applied / skipped。
  String applyRemoteChange(ChangeRecord c, {required String fromDevice}) {
    return _db.transaction(() {
      final localAt = changes.latestAt(c.entity, c.entityId);
      if (localAt != null && localAt > c.at) {
        _audit(Actor.automation, 'sync.conflict_skipped', c.entity, c.entityId, after: {'remote_at': c.at, 'local_at': localAt, 'from': fromDevice});
        return 'skipped';
      }
      final p = c.payload ?? const <String, Object?>{};
      final ts = _nowMs();
      switch (c.entity) {
        case 'account':
          if (c.deleted) {
            // 对方删了：本机没有它的交易 / 目标 / 周期项就跟着删；有（对方没同步到的记录）就退成归档，历史不丢
            if (account(c.entityId) == null) break;
            final inUse = accountPostingCount(c.entityId) > 0 ||
                (_db.select('SELECT COUNT(*) AS n FROM goals WHERE vault_account_id = ? OR linked_account_id = ?', [c.entityId, c.entityId]).first['n'] as int) > 0 ||
                (_db.select("SELECT COUNT(*) AS n FROM recurring WHERE template LIKE '%' || ? || '%'", [c.entityId]).first['n'] as int) > 0;
            if (inUse) {
              _db.execute('UPDATE accounts SET is_archived = 1, updated_at = ? WHERE id = ?', [ts, c.entityId]);
            } else {
              _db.execute('UPDATE memory_map SET account_id = NULL WHERE account_id = ?', [c.entityId]);
              if (profile.salaryAccountId == c.entityId) profile.salaryAccountId = null;
              _db.execute('DELETE FROM accounts WHERE id = ?', [c.entityId]);
            }
            break;
          }
          _db.execute(
            'INSERT OR REPLACE INTO accounts(id,name,type,currency,initial_balance_minor,institution,icon,is_archived,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,COALESCE((SELECT created_at FROM accounts WHERE id = ?),?),?)',
            [p['id'], p['name'], p['type'], p['currency'], p['initial_balance_minor'] ?? 0, p['institution'], p['icon'], p['is_archived'] == true ? 1 : 0, p['sort_order'] ?? 0, p['id'], ts, ts],
          );
        case 'category':
          if (c.deleted) {
            // 对方删了，但本机还有交易 / 子分类 / 预算在用（对方没同步到的记录）：保留，别让外键把整轮同步卡死
            int n(String sql) => _db.select(sql, [c.entityId]).first['n'] as int;
            final inUse = n('SELECT COUNT(*) AS n FROM transactions WHERE category_id = ?') > 0 ||
                n('SELECT COUNT(*) AS n FROM categories WHERE parent_id = ?') > 0 ||
                n('SELECT COUNT(*) AS n FROM budgets WHERE category_id = ?') > 0;
            if (inUse) {
              _audit(Actor.automation, 'sync.delete_kept', 'category', c.entityId, after: {'from': fromDevice, 'reason': 'in use locally'});
              return 'skipped';
            }
            _db.execute('UPDATE memory_map SET category_id = NULL WHERE category_id = ?', [c.entityId]);
            _db.execute('DELETE FROM categories WHERE id = ?', [c.entityId]);
          } else {
            _db.execute('INSERT OR REPLACE INTO categories(id,parent_id,kind,name,icon,is_default,sort_order) VALUES (?,?,?,?,?,?,?)',
                [p['id'], p['parent_id'], p['kind'], p['name'], p['icon'], p['is_default'] == true ? 1 : 0, p['sort_order'] ?? 0]);
          }
        case 'transaction':
          if (c.deleted) break; // 交易只作废不删
          final occ = OccurredAt.parse(p['occurred_at'] as String);
          _db.execute(
            'INSERT OR REPLACE INTO transactions(id,type,occurred_at_ms,tz_offset_min,currency,merchant,description,category_id,tags,source,status,'
            'confidence,refund_of_id,recurring_id,event_fingerprint,metadata,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,COALESCE((SELECT created_at FROM transactions WHERE id = ?),?),?)',
            [
              p['id'], p['type'], occ.millis, occ.offsetMinutes, p['currency'], p['merchant'], p['description'], p['category_id'],
              jsonEncode(p['tags'] ?? const []), p['source'] ?? 'manual', p['status'] ?? 'confirmed', p['confidence'], p['refund_of_id'],
              p['recurring_id'], p['event_fingerprint'], jsonEncode(p['metadata'] ?? const {}), p['id'], ts, ts,
            ],
          );
          _db.execute('DELETE FROM postings WHERE transaction_id = ?', [c.entityId]);
          for (final po in (p['postings'] as List? ?? const []).cast<Map>()) {
            _db.execute('INSERT INTO postings(id,transaction_id,account_id,amount_minor) VALUES (?,?,?,?)', [po['id'] ?? Ulid.next(), c.entityId, po['account_id'], po['amount_minor']]);
          }
        case 'memory':
          c.deleted ? memory.deleteRaw(c.entityId) : memory.upsertRaw(p);
        case 'recurring':
          c.deleted ? recurring.deleteRaw(c.entityId) : recurring.upsertRaw(p);
        case 'budget':
          c.deleted ? budgets.deleteRaw(c.entityId) : budgets.upsertRaw(p);
        case 'goal':
          c.deleted ? goals.deleteRaw(c.entityId) : goals.upsertRaw(p);
        case 'task':
          c.deleted ? tasks.deleteRaw(c.entityId) : tasks.upsertRaw(p);
        case 'achievement':
          c.deleted ? achievements.deleteRaw(c.entityId) : achievements.upsertRaw(p);
        case 'profile':
          c.deleted ? profile.deleteRaw(c.entityId) : profile.upsertRaw(p);
        default:
          throw ValidationException('entity', 'unknown entity ${c.entity}');
      }
      changes.record(c.entity, c.entityId, c.payload, deleted: c.deleted, origin: fromDevice, at: c.at);
      _audit(Actor.automation, 'sync.apply', c.entity, c.entityId, after: {'from': fromDevice, 'deleted': c.deleted});
      return 'applied';
    });
  }

  /// 一条远端变更应用失败（坏数据 / 本机缺它依赖的账户……）：整条回滚后在这里留痕，同步继续往后走，不卡死在这一条。
  /// 审计里带着原始载荷，之后能人工看、也能重放。
  void recordSyncFailure(ChangeRecord c, {required String fromDevice, required Object error}) {
    _audit(Actor.automation, 'sync.apply_failed', c.entity, c.entityId,
        after: {'from': fromDevice, 'error': '$error', 'deleted': c.deleted, 'at': c.at, 'payload': c.payload});
  }

  /// 应用失败过的远端变更（新在前）。
  List<AuditEntry> syncFailures({int limit = 50}) => _db
      .select("SELECT * FROM audit_log WHERE action = 'sync.apply_failed' ORDER BY seq DESC LIMIT ?", [limit])
      .map(AuditEntry.fromRow)
      .toList();

  static int? _parseIsoMs(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc().millisecondsSinceEpoch : null;

  // ------------------------------------------------------------------- audit

  /// 目标 / 任务 / 成就的审计入口（这些 store 在 ledger 外面，但审计表只有 ledger 能写）。
  void auditGoal(String action, String targetId, {Map<String, Object?>? before, Map<String, Object?>? after}) =>
      _audit(action.startsWith('achievement') || action.startsWith('task.settle') ? Actor.automation : Actor.user, action, action.split('.').first, targetId, before: before, after: after, confirmed: !action.startsWith('achievement') && !action.startsWith('task.settle'));

  void _audit(
    Actor actor,
    String action,
    String targetType,
    String targetId, {
    Map<String, Object?>? before,
    Map<String, Object?>? after,
    String? draftId,
    String? modelUsed,
    String? interpreter,
    bool confirmed = false,
  }) {
    _db.execute(
      'INSERT INTO audit_log(id,at,actor,action,target_type,target_id,before_json,after_json,draft_id,model_used,interpreter,confirmed_by_user) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        Ulid.next(), _nowMs(), actor.db, action, targetType, targetId,
        before == null ? null : jsonEncode(before), after == null ? null : jsonEncode(after),
        draftId, modelUsed, interpreter, confirmed ? 1 : 0,
      ],
    );
  }

  /// 一个对象的完整历史：直接命中的条目，加上经由同一草稿关联的条目
  /// （从交易 id 能追到产生它的 propose / commit）。
  List<AuditEntry> auditFor(String targetId) {
    final direct = _db.select(
        'SELECT * FROM audit_log WHERE target_id = ? OR draft_id = ?', [targetId, targetId]).map(AuditEntry.fromRow);
    final draftIds = {for (final e in direct) if (e.draftId != null) e.draftId!};
    final ids = <String>{};
    final out = <AuditEntry>[];
    void add(Iterable<AuditEntry> es) {
      for (final e in es) {
        if (ids.add(e.id)) out.add(e);
      }
    }
    add(direct);
    for (final did in draftIds) {
      add(_db.select('SELECT * FROM audit_log WHERE draft_id = ?', [did]).map(AuditEntry.fromRow));
    }
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  /// 修剪审计日志里只有机器看的流水（同步应用、指纹去重、冲突跳过）：超过 [keepDays] 天的删掉。
  /// 用户操作、落账、作废、失败留痕（sync.apply_failed）都不动。返回删掉的条数。
  int pruneAudit({int keepDays = 90}) {
    final cutoff = _nowMs() - Duration(days: keepDays).inMilliseconds;
    final n = _db.select("SELECT COUNT(*) AS n FROM audit_log WHERE at < ? AND action IN ('sync.apply', 'draft.dedupe', 'sync.conflict_skipped', 'sync.delete_kept')", [cutoff]).first['n'] as int;
    if (n > 0) _db.execute("DELETE FROM audit_log WHERE at < ? AND action IN ('sync.apply', 'draft.dedupe', 'sync.conflict_skipped', 'sync.delete_kept')", [cutoff]);
    return n;
  }

  /// 本地存储维护（启动时调一次）：变更日志压缩 + 审计流水修剪。便宜的检查，数量不大就什么都不做。
  ({int changes, int audit}) maintain({int changeThreshold = 5000}) {
    final c = changes.count > changeThreshold ? changes.compact() : 0;
    return (changes: c, audit: pruneAudit());
  }

  /// 所有账户的余额一次算完（一条聚合 SQL，不是每个账户查一次）。
  Map<String, int> balanceMinorByAccount() {
    final out = <String, int>{};
    for (final a in _db.select('SELECT id, initial_balance_minor FROM accounts')) {
      out[a['id'] as String] = a['initial_balance_minor'] as int;
    }
    for (final r in _db.select("SELECT p.account_id AS a, SUM(p.amount_minor) AS s FROM postings p JOIN transactions t ON t.id = p.transaction_id WHERE t.status = 'confirmed' GROUP BY p.account_id")) {
      final id = r['a'] as String;
      out[id] = (out[id] ?? 0) + (r['s'] as int);
    }
    return out;
  }

  List<AuditEntry> auditLog({int limit = 200}) =>
      _db.select('SELECT * FROM audit_log ORDER BY seq DESC LIMIT ?', [limit]).map(AuditEntry.fromRow).toList();

  /// 完整性自检：每笔已确认交易的 posting 结构与 type 一致。返回问题列表，空即健康。
  List<String> integrityCheck() {
    final problems = <String>[];
    for (final t in listTransactions(limit: 1 << 30)) {
      final ps = t.postings;
      switch (t.type) {
        case TransactionType.expense:
          if (ps.length != 1 || ps.first.amountMinor >= 0) problems.add('${t.id}: expense posting invalid');
        case TransactionType.income:
        case TransactionType.refund:
          if (ps.length != 1 || ps.first.amountMinor <= 0) problems.add('${t.id}: ${t.type.db} posting invalid');
        case TransactionType.transfer:
          if (ps.length != 2 || ps[0].amountMinor + ps[1].amountMinor != 0 || ps[0].accountId == ps[1].accountId) {
            problems.add('${t.id}: transfer postings invalid');
          }
        case TransactionType.adjustment:
          if (ps.length != 1 || ps.first.amountMinor == 0) problems.add('${t.id}: adjustment posting invalid');
      }
      for (final p in ps) {
        final a = account(p.accountId);
        if (a == null) {
          problems.add('${t.id}: posting account missing');
        } else if (a.currency != t.currency) {
          problems.add('${t.id}: posting currency mismatch');
        }
      }
    }
    return problems;
  }
}
