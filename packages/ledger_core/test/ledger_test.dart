import 'dart:io';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 固定时钟：2026-09-15 12:00 +08:00
final fixedNow = DateTime.utc(2026, 9, 15, 4);
const at = '2026-09-15T12:00:00+08:00';

late LedgerDatabase db;
late Ledger ledger;
late Account wechat;
late Account bank;
late Account usd;

void setUpLedger() {
  db = openLedgerDatabaseInMemory();
  ledger = Ledger(db, clock: () => fixedNow);
  ledger.seedDefaultCategories();
  wechat = ledger.createAccount(name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 100000);
  bank = ledger.createAccount(name: '工行', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 500000);
  usd = ledger.createAccount(name: 'USD 卡', type: AccountType.bank, currency: 'USD');
}

Map<String, Object?> expense(int minor, {String? account, String? category = 'food', String? when}) => {
      'type': 'expense',
      'amount_minor': minor,
      'currency': 'CNY',
      'account_id': account ?? wechat.id,
      'category_id': category,
      'description': '午餐',
      'occurred_at': when ?? at,
    };

Draft proposeOne(Map<String, Object?> payload, {DraftKind kind = DraftKind.create, String? target, String? fp, bool exact = false}) =>
    ledger.propose(
      [DraftInput(kind: kind, targetTransactionId: target, payload: payload, eventFingerprint: fp, fingerprintIsExact: exact)],
      source: Source.chat,
      interpreter: 'test',
    ).single;

void main() {
  setUp(setUpLedger);
  tearDown(() => db.close());

  group('schema', () {
    test('migrated to latest', () {
      expect(db.schemaVersion, 2);
    });
    test('persists across reopen', () {
      final dir = Directory.systemTemp.createTempSync('yujian_');
      final path = '${dir.path}/ledger.db';
      final d1 = openLedgerDatabase(path);
      final l1 = Ledger(d1, clock: () => fixedNow)..seedDefaultCategories();
      final a = l1.createAccount(name: '现金', type: AccountType.cash, currency: 'CNY', initialBalanceMinor: 1000);
      final dr = l1.propose([DraftInput(payload: {...expense(300), 'account_id': a.id})], source: Source.manual).single;
      l1.commit(dr.id);
      d1.close();
      final d2 = openLedgerDatabase(path);
      final l2 = Ledger(d2);
      expect(l2.balance(a.id).minor, 700);
      expect(l2.listTransactions().length, 1);
      d2.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('accounts', () {
    test('balance = initial with no transactions', () {
      expect(ledger.balance(wechat.id), const Money(100000, 'CNY'));
    });
    test('unknown currency rejected', () {
      expect(() => ledger.createAccount(name: 'x', type: AccountType.cash, currency: 'ABC'), throwsA(isA<ValidationException>()));
    });
    test('archive hides from list and blocks new postings', () {
      ledger.archiveAccount(usd.id);
      expect(ledger.listAccounts().map((a) => a.id), isNot(contains(usd.id)));
      expect(ledger.listAccounts(includeArchived: true).map((a) => a.id), contains(usd.id));
      final d = proposeOne({...expense(100), 'account_id': usd.id, 'currency': 'USD'});
      expect(d.missingFields, contains('account_id'));
    });
  });

  group('categories', () {
    test('seed is idempotent', () {
      ledger.seedDefaultCategories();
      expect(ledger.listCategories(kind: CategoryKind.expense).length, 13);
      expect(ledger.listCategories(kind: CategoryKind.income).length, 6);
    });
    test('child must match parent kind', () {
      expect(() => ledger.createCategory(name: '咖啡', kind: CategoryKind.income, parentId: 'food'),
          throwsA(isA<ValidationException>()));
      final c = ledger.createCategory(name: '咖啡', kind: CategoryKind.expense, parentId: 'food');
      expect(c.parentId, 'food');
    });
  });

  group('propose → commit: expense', () {
    test('creates one negative posting and moves balance', () {
      final d = proposeOne(expense(2800));
      expect(d.status, DraftStatus.pending);
      expect(d.missingFields, isEmpty);
      final tx = ledger.commit(d.id);
      expect(tx.type, TransactionType.expense);
      expect(tx.postings.single.amountMinor, -2800);
      expect(tx.amountMinor, 2800);
      expect(tx.accountId, wechat.id);
      expect(tx.categoryId, 'food');
      expect(tx.occurredAt.toIso8601String(), '2026-09-15T12:00:00.000+08:00');
      expect(ledger.balance(wechat.id).minor, 100000 - 2800);
      expect(ledger.getDraft(d.id).status, DraftStatus.committed);
      expect(ledger.getDraft(d.id).committedTransactionId, tx.id);
    });

    test('commit is idempotent', () {
      final d = proposeOne(expense(2800));
      final t1 = ledger.commit(d.id);
      final t2 = ledger.commit(d.id);
      expect(t2.id, t1.id);
      expect(ledger.listTransactions().length, 1);
      expect(ledger.balance(wechat.id).minor, 100000 - 2800);
    });

    test('edits override draft payload and are audited', () {
      final d = proposeOne(expense(2800));
      final tx = ledger.commit(d.id, edits: {'category_id': 'transport', 'amount_minor': 2400});
      expect(tx.categoryId, 'transport');
      expect(tx.amountMinor, 2400);
      final audit = ledger.auditFor(d.id);
      final commitEntry = audit.firstWhere((e) => e.action == 'draft.commit');
      expect(commitEntry.before?['category_id'], 'food');
      expect(commitEntry.after?['category_id'], 'transport');
      expect(commitEntry.confirmedByUser, isTrue);
      expect(commitEntry.interpreter, 'test');
    });

    test('audit trail covers propose, commit and create', () {
      final d = proposeOne(expense(100));
      final tx = ledger.commit(d.id);
      final actions = ledger.auditFor(tx.id).map((e) => e.action).toList();
      expect(actions, containsAll(['draft.propose', 'draft.commit', 'transaction.create']));
      final propose = ledger.auditFor(d.id).firstWhere((e) => e.action == 'draft.propose');
      expect(propose.actor, Actor.interpreter);
      expect(propose.confirmedByUser, isFalse);
    });

    test('missing fields keep draft pending and block commit', () {
      final d = proposeOne({'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'occurred_at': at});
      expect(d.missingFields, containsAll(['account_id', 'category_id']));
      expect(() => ledger.commit(d.id), throwsA(isA<MissingFieldsException>()));
      final tx = ledger.commit(d.id, edits: {'account_id': wechat.id, 'category_id': 'food'});
      expect(tx.amountMinor, 2800);
    });

    test('rule violations are reported per field', () {
      final d = proposeOne({...expense(-5), 'category_id': 'salary', 'occurred_at': '2026-09-20T00:00:00+08:00'});
      expect(d.missingFields, containsAll(['amount_minor', 'category_id', 'occurred_at']));
      expect(() => ledger.commit(d.id), throwsA(isA<ValidationException>()));
    });

    test('naive occurred_at rejected (no timezone guessing)', () {
      final d = proposeOne(expense(100, when: '2026-09-15T12:00:00'));
      expect(d.missingFields, contains('occurred_at'));
    });

    test('float amount rejected', () {
      final d = proposeOne({...expense(100), 'amount_minor': 28.0});
      expect(d.missingFields, contains('amount_minor'));
    });

    test('account currency must match', () {
      final d = proposeOne({...expense(100), 'account_id': usd.id});
      expect(d.missingFields, contains('account_id'));
    });

    test('dismiss then commit is refused', () {
      final d = proposeOne(expense(100));
      ledger.dismiss(d.id);
      expect(() => ledger.commit(d.id), throwsA(isA<InvalidStateException>()));
      expect(() => ledger.dismiss(d.id), throwsA(isA<InvalidStateException>()));
    });
  });

  group('income / transfer / refund / adjustment', () {
    test('income adds a positive posting', () {
      final d = proposeOne({'type': 'income', 'amount_minor': 1500000, 'currency': 'CNY', 'account_id': bank.id, 'category_id': 'salary', 'occurred_at': at});
      ledger.commit(d.id);
      expect(ledger.balance(bank.id).minor, 500000 + 1500000);
    });

    test('transfer produces two postings summing to zero', () {
      final d = proposeOne({'type': 'transfer', 'amount_minor': 20000, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': wechat.id, 'occurred_at': at});
      final tx = ledger.commit(d.id);
      expect(tx.postings.length, 2);
      expect(tx.postings.map((p) => p.amountMinor).reduce((a, b) => a + b), 0);
      expect(tx.toAccountId, wechat.id);
      expect(ledger.balance(bank.id).minor, 480000);
      expect(ledger.balance(wechat.id).minor, 120000);
    });

    test('transfer rejects same account, cross currency and category', () {
      expect(proposeOne({'type': 'transfer', 'amount_minor': 1, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': bank.id, 'occurred_at': at}).missingFields,
          contains('to_account_id'));
      expect(proposeOne({'type': 'transfer', 'amount_minor': 1, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': usd.id, 'occurred_at': at}).missingFields,
          contains('to_account_id'));
      expect(proposeOne({'type': 'transfer', 'amount_minor': 1, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': wechat.id, 'category_id': 'food', 'occurred_at': at}).missingFields,
          contains('category_id'));
    });

    test('refund inherits category, is capped by remaining amount', () {
      final orig = ledger.commit(proposeOne(expense(10000)).id);
      final r1 = ledger.commit(proposeOne({'type': 'refund', 'amount_minor': 6000, 'currency': 'CNY', 'account_id': wechat.id, 'refund_of_id': orig.id, 'occurred_at': at}).id);
      expect(r1.categoryId, 'food');
      expect(r1.postings.single.amountMinor, 6000);
      expect(ledger.balance(wechat.id).minor, 100000 - 10000 + 6000);
      final tooMuch = proposeOne({'type': 'refund', 'amount_minor': 5000, 'currency': 'CNY', 'account_id': wechat.id, 'refund_of_id': orig.id, 'occurred_at': at});
      expect(tooMuch.missingFields, contains('amount_minor'));
      final ok = proposeOne({'type': 'refund', 'amount_minor': 4000, 'currency': 'CNY', 'account_id': wechat.id, 'refund_of_id': orig.id, 'occurred_at': at});
      expect(ok.missingFields, isEmpty);
    });

    test('refund of a transfer or void transaction is refused', () {
      final tr = ledger.commit(proposeOne({'type': 'transfer', 'amount_minor': 100, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': wechat.id, 'occurred_at': at}).id);
      expect(proposeOne({'type': 'refund', 'amount_minor': 50, 'currency': 'CNY', 'account_id': wechat.id, 'refund_of_id': tr.id, 'occurred_at': at}).missingFields,
          contains('refund_of_id'));
    });

    test('adjustment needs reason and direction', () {
      final d = proposeOne({'type': 'adjustment', 'amount_minor': 300, 'currency': 'CNY', 'account_id': wechat.id, 'occurred_at': at});
      expect(d.missingFields, containsAll(['description', 'metadata.direction']));
      final tx = ledger.commit(d.id, edits: {'description': '对账差额', 'metadata': {'direction': 'decrease'}});
      expect(tx.postings.single.amountMinor, -300);
      expect(ledger.balance(wechat.id).minor, 99700);
    });
  });

  group('update / void drafts', () {
    test('update draft patches category and audits before/after', () {
      final tx = ledger.commit(proposeOne(expense(2800)).id);
      final u = proposeOne({'category_id': 'transport'}, kind: DraftKind.update, target: tx.id);
      expect(u.missingFields, isEmpty);
      final after = ledger.commit(u.id);
      expect(after.id, tx.id);
      expect(after.categoryId, 'transport');
      expect(after.amountMinor, 2800);
      final e = ledger.auditFor(tx.id).firstWhere((e) => e.action == 'transaction.update');
      expect(e.before?['category_id'], 'food');
      expect(e.after?['category_id'], 'transport');
    });

    test('"this is a transfer, not an expense" rebuilds postings', () {
      final tx = ledger.commit(proposeOne(expense(20000)).id);
      final u = proposeOne({'type': 'transfer', 'to_account_id': bank.id, 'category_id': null}, kind: DraftKind.update, target: tx.id);
      expect(u.missingFields, isEmpty);
      final after = ledger.commit(u.id);
      expect(after.type, TransactionType.transfer);
      expect(after.postings.length, 2);
      expect(ledger.balance(wechat.id).minor, 80000);
      expect(ledger.balance(bank.id).minor, 520000);
      expect(ledger.integrityCheck(), isEmpty);
    });

    test('update draft on unknown target is flagged', () {
      final u = proposeOne({'category_id': 'transport'}, kind: DraftKind.update, target: 'nope');
      expect(u.missingFields, contains('target_transaction_id'));
    });

    test('void restores balance, needs reason, blocked while refunds exist', () {
      final tx = ledger.commit(proposeOne(expense(2800)).id);
      final noReason = proposeOne({}, kind: DraftKind.void_, target: tx.id);
      expect(noReason.missingFields, contains('reason'));
      final v = proposeOne({'reason': '记错了'}, kind: DraftKind.void_, target: tx.id);
      final after = ledger.commit(v.id);
      expect(after.status, TransactionStatus.void_);
      expect(after.metadata['void_reason'], '记错了');
      expect(ledger.balance(wechat.id).minor, 100000);
      expect(ledger.listTransactions(), isEmpty);
      expect(ledger.listTransactions(status: TransactionStatus.void_).length, 1);

      final orig = ledger.commit(proposeOne(expense(10000)).id);
      ledger.commit(proposeOne({'type': 'refund', 'amount_minor': 1000, 'currency': 'CNY', 'account_id': wechat.id, 'refund_of_id': orig.id, 'occurred_at': at}).id);
      final v2 = proposeOne({'reason': 'x'}, kind: DraftKind.void_, target: orig.id);
      expect(() => ledger.commit(v2.id), throwsA(isA<InvalidStateException>()));
    });
  });

  group('groups and dedupe', () {
    test('multi-item propose shares group_id; commitGroup commits all', () {
      final ds = ledger.propose(
        [DraftInput(payload: expense(6800)), DraftInput(payload: expense(2400, category: 'transport')), DraftInput(payload: expense(4500, category: 'entertainment'))],
        source: Source.chat,
      );
      expect(ds.map((d) => d.groupId).toSet().length, 1);
      final txs = ledger.commitGroup(ds.first.groupId);
      expect(txs.length, 3);
      expect(ledger.balance(wechat.id).minor, 100000 - 6800 - 2400 - 4500);
    });

    test('commitGroup is atomic: one bad draft rolls back the whole group', () {
      final ds = ledger.propose(
        [DraftInput(payload: expense(6800)), DraftInput(payload: {'type': 'expense', 'amount_minor': 1, 'currency': 'CNY', 'occurred_at': at})],
        source: Source.chat,
      );
      expect(() => ledger.commitGroup(ds.first.groupId), throwsA(isA<MissingFieldsException>()));
      expect(ledger.listTransactions(), isEmpty);
      expect(ledger.getDraft(ds.first.id).status, DraftStatus.pending);
      expect(ledger.balance(wechat.id).minor, 100000);
    });

    test('exact fingerprint duplicate is dropped and audited', () {
      final first = proposeOne(expense(100), fp: 'wechat:evt-1:acc', exact: true);
      ledger.commit(first.id);
      final again = ledger.propose(
        [DraftInput(payload: expense(100), eventFingerprint: 'wechat:evt-1:acc', fingerprintIsExact: true)],
        source: Source.notification,
        actor: Actor.automation,
      );
      expect(again, isEmpty);
      expect(ledger.listTransactions().length, 1);
      expect(ledger.auditLog().first.action, 'draft.dedupe');
    });

    test('candidate fingerprint hit is kept but flagged', () {
      final first = proposeOne(expense(100), fp: 'cand:瑞幸:2800:w', exact: false);
      final second = proposeOne(expense(100), fp: 'cand:瑞幸:2800:w', exact: false);
      expect(second.possibleDuplicateOf, first.id);
      expect(second.status, DraftStatus.pending);
    });
  });

  group('queries', () {
    test('listTransactions filters by range, account, category, type', () {
      ledger.commit(proposeOne(expense(100, when: '2026-09-01T10:00:00+08:00')).id);
      ledger.commit(proposeOne(expense(200, category: 'transport', when: '2026-09-10T10:00:00+08:00')).id);
      ledger.commit(proposeOne({'type': 'income', 'amount_minor': 999, 'currency': 'CNY', 'account_id': bank.id, 'category_id': 'salary', 'occurred_at': at}).id);
      expect(ledger.listTransactions().length, 3);
      expect(ledger.listTransactions(from: DateTime.utc(2026, 9, 5)).length, 2);
      expect(ledger.listTransactions(to: DateTime.utc(2026, 9, 5)).length, 1);
      expect(ledger.listTransactions(accountId: bank.id).length, 1);
      expect(ledger.listTransactions(categoryId: 'transport').single.amountMinor, 200);
      expect(ledger.listTransactions(type: TransactionType.income).single.amountMinor, 999);
    });

    test('integrity check passes on a mixed ledger', () {
      ledger.commit(proposeOne(expense(100)).id);
      ledger.commit(proposeOne({'type': 'transfer', 'amount_minor': 5, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': wechat.id, 'occurred_at': at}).id);
      expect(ledger.integrityCheck(), isEmpty);
    });
  });
}
