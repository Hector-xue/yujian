import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 两台设备各自一份账本，通过变更日志互相应用，模拟同步。
void main() {
  late Ledger a;
  late Ledger b;
  final base = DateTime.utc(2026, 9, 15, 4).millisecondsSinceEpoch;
  var clock = 0;
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(base + clock, isUtc: true);

  setUp(() {
    clock = 0;
    a = Ledger(openLedgerDatabaseInMemory(), clock: now)..seedDefaultCategories();
    b = Ledger(openLedgerDatabaseInMemory(), clock: now)..seedDefaultCategories();
  });

  /// 把 from 的待推变更应用到 to（相当于 push 到服务端再被 to pull）。
  List<String> sync(Ledger from, Ledger to) {
    final pending = from.changes.pending();
    final results = [for (final c in pending) to.applyRemoteChange(c, fromDevice: from.changes.deviceId)];
    from.changes.markPushed(pending.map((c) => c.seq));
    return results;
  }

  test('every write records exactly one change; default seeds do not', () {
    expect(a.changes.pending(), isEmpty);
    final acc = a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    a.createCategory(id: 'food.coffee', name: '咖啡', kind: CategoryKind.expense, parentId: 'food');
    final tx = a.commit(a.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'account_id': acc.id, 'category_id': 'food', 'merchant': '面馆', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);
    a.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 1, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2027-01-01');
    a.budgets.create(name: 'b', amountMinor: 100, startDate: '2026-09-01');
    final entities = a.changes.pending().map((c) => '${c.entity}:${c.entityId}').toList();
    expect(entities, ['account:w', 'category:food.coffee', 'transaction:${tx.id}', 'memory:面馆', 'recurring:${a.recurring.list().single.id}', 'budget:${a.budgets.list().single.id}']);
    expect(a.changes.pendingCount, 6);
    expect(a.changes.deviceId, a.changes.deviceId);
    expect(a.changes.deviceId, isNot(b.changes.deviceId));
  });

  test('a → b replicates accounts, transactions, postings and balances', () {
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 10000);
    a.commit(a.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'food', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);
    expect(sync(a, b), ['applied', 'applied']);
    expect(b.balance('w').minor, 7200);
    expect(b.listTransactions().single.postings.single.amountMinor, -2800);
    expect(b.integrityCheck(), isEmpty);
    expect(a.changes.pendingCount, 0);
    expect(b.changes.pendingCount, 0, reason: '应用远端变更不产生待推变更');
    expect(b.auditLog().first.action, 'sync.apply');
  });

  test('last writer wins per entity; loser is audited', () {
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    final tx = a.commit(a.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'food', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);
    sync(a, b);
    // b 在 t=2000 改分类；a 在 t=3000 改分类
    clock = 2000;
    b.commit(b.propose([DraftInput(kind: DraftKind.update, targetTransactionId: tx.id, payload: {'category_id': 'daily'})], source: Source.manual).single.id);
    clock = 3000;
    a.commit(a.propose([DraftInput(kind: DraftKind.update, targetTransactionId: tx.id, payload: {'category_id': 'transport'})], source: Source.manual).single.id);
    expect(sync(b, a), ['skipped']);
    expect(a.getTransaction(tx.id).categoryId, 'transport');
    expect(a.auditLog().first.action, 'sync.conflict_skipped');
    expect(sync(a, b), ['applied']);
    expect(b.getTransaction(tx.id).categoryId, 'transport');
  });

  test('deletes replicate as tombstones for budget/recurring/memory', () {
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    final bud = a.budgets.create(name: 'b', amountMinor: 100, startDate: '2026-09-01');
    sync(a, b);
    expect(b.budgets.list().length, 1);
    clock = 2000;
    a.budgets.delete(bud.id);
    sync(a, b);
    expect(b.budgets.list(), isEmpty);
  });

  test('restore clears the log and replays everything as local changes', () {
    a.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    a.commit(a.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'w', 'category_id': 'food', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.chat).single.id);
    sync(a, b);
    final backup = exportJson(a);
    final c = Ledger(openLedgerDatabaseInMemory(), clock: now);
    restoreFromJson(c, backup);
    expect(c.changes.pending().map((x) => x.entity).toSet(), {'account', 'transaction'});
  });
}
