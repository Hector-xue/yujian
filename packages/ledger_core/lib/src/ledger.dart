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
import 'money.dart';
import 'validation.dart';

/// 账本门面（§18.1）。上层（UI / Interpreter / MCP）只通过这里读写账本。
/// 写路径永远是 propose → commit；没有任何绕过草稿直接写交易的入口。
class Ledger implements ValidationContext {
  final LedgerDatabase _db;
  final DateTime Function() _clock;

  Ledger(this._db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

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
      return a;
    });
  }

  @override
  Account? account(String id) {
    final rows = _db.select('SELECT * FROM accounts WHERE id = ?', [id]);
    return rows.isEmpty ? null : Account.fromRow(rows.first);
  }

  Account getAccount(String id) => account(id) ?? (throw NotFoundException('account', id));

  List<Account> listAccounts({bool includeArchived = false}) => _db
      .select('SELECT * FROM accounts ${includeArchived ? '' : 'WHERE is_archived = 0'} ORDER BY sort_order, created_at')
      .map(Account.fromRow)
      .toList();

  void archiveAccount(String id) {
    final before = getAccount(id);
    if (before.isArchived) throw InvalidStateException('account already archived');
    _db.transaction(() {
      _db.execute('UPDATE accounts SET is_archived = 1, updated_at = ? WHERE id = ?', [_nowMs(), id]);
      _audit(Actor.user, 'account.archive', 'account', id,
          before: before.toJson(), after: getAccount(id).toJson(), confirmed: true);
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

  Map<String, Money> balances({bool includeArchived = false}) =>
      {for (final a in listAccounts(includeArchived: includeArchived)) a.id: balance(a.id)};

  // -------------------------------------------------------------- categories

  void seedDefaultCategories() {
    _db.transaction(() {
      for (final c in defaultCategories) {
        _db.execute(
          'INSERT OR IGNORE INTO categories(id,parent_id,kind,name,icon,is_default,sort_order) VALUES (?,?,?,?,?,1,?)',
          [c.id, c.parentId, c.kind.db, c.name, c.icon, c.sortOrder],
        );
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
      return c;
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

      final finalPayload = {...d.payload, ...?edits};
      final Transaction tx;
      switch (d.kind) {
        case DraftKind.create:
          tx = _createTransaction(finalPayload, d);
        case DraftKind.update:
          tx = _updateTransaction(d.targetTransactionId!, finalPayload, d);
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
        v.categoryId, jsonEncode(v.tags), d.source.db, d.confidence, v.refundOfId, null, d.eventFingerprint,
        jsonEncode(v.metadata), ts, ts,
      ],
    );
    _insertPostings(id, v);
    final tx = getTransaction(id);
    _audit(Actor.user, 'transaction.create', 'transaction', id,
        after: tx.toJson(), draftId: d.id, interpreter: d.interpreter, modelUsed: d.modelUsed, confirmed: true);
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
    return [for (final r in rows) Transaction.fromRow(r, _postingsOf(r['id'] as String))];
  }

  // ------------------------------------------------------------------- audit

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
