import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late LedgerDatabase db;
  late Ledger ledger;
  late Account wechat;
  late Account cash;
  const at = '2026-09-15T12:00:00+08:00';

  setUp(() {
    db = openLedgerDatabaseInMemory();
    ledger = Ledger(db, clock: () => DateTime.utc(2026, 9, 15, 4))..seedDefaultCategories();
    wechat = ledger.createAccount(name: '微信', type: AccountType.eWallet, currency: 'CNY');
    cash = ledger.createAccount(name: '现金', type: AccountType.cash, currency: 'CNY');
  });
  tearDown(() => db.close());

  Draft propose({String? merchant, String? desc, String cat = 'food', String? account}) => ledger.propose(
        [DraftInput(payload: {'type': 'expense', 'amount_minor': 2200, 'currency': 'CNY', 'account_id': account ?? wechat.id, 'category_id': cat, 'merchant': merchant, 'description': desc, 'occurred_at': at})],
        source: Source.chat,
      ).single;

  test('schema is at version 5', () => expect(db.schemaVersion, 5));

  test('correction in inbox becomes a high-confidence merchant mapping', () {
    ledger.commit(propose(merchant: '楼下面馆', cat: 'shopping').id, edits: {'category_id': 'food', 'account_id': cash.id});
    final m = ledger.memory.get('楼下面馆')!;
    expect(m.kind, 'merchant');
    expect(m.categoryId, 'food');
    expect(m.accountId, cash.id);
    expect(m.source, 'user_correction');
    expect(m.confidence, greaterThanOrEqualTo(0.95));
  });

  test('plain confirmations reinforce slowly and never overwrite a correction', () {
    ledger.commit(propose(merchant: '瑞幸', cat: 'food').id);
    expect(ledger.memory.get('瑞幸')!.confidence, lessThan(0.9));
    ledger.commit(propose(merchant: '瑞幸', cat: 'shopping').id, edits: {'category_id': 'daily'});
    expect(ledger.memory.get('瑞幸')!.categoryId, 'daily');
    ledger.commit(propose(merchant: '瑞幸', cat: 'food').id); // 没改 → 不推翻纠正
    final m = ledger.memory.get('瑞幸')!;
    expect(m.categoryId, 'daily');
    expect(m.hits, 3);
    expect(m.corrections, 1);
  });

  test('description is used as keyword key when no merchant; junk keys skipped', () {
    ledger.commit(propose(desc: '打车', cat: 'transport').id);
    expect(ledger.memory.get('打车')!.kind, 'keyword');
    ledger.commit(propose(desc: '28', cat: 'food').id);
    expect(ledger.memory.get('28'), isNull);
    ledger.commit(propose(desc: '这是一个特别特别长的描述不该成为键', cat: 'food').id);
    expect(ledger.memory.all().length, 1);
  });

  test('changing category on an existing transaction also teaches', () {
    final tx = ledger.commit(propose(merchant: '山姆', cat: 'food').id);
    final u = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: tx.id, payload: {'category_id': 'daily'})], source: Source.manual).single;
    ledger.commit(u.id);
    expect(ledger.memory.get('山姆')!.categoryId, 'daily');
    expect(ledger.memory.get('山姆')!.corrections, 1);
  });

  test('forget', () {
    ledger.commit(propose(merchant: 'x店').id);
    ledger.memory.forget('x店');
    expect(ledger.memory.get('x店'), isNull);
  });
}
