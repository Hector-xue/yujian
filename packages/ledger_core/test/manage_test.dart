import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

void main() {
  late Ledger l;
  late Account w;
  setUp(() {
    l = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 9, 15, 4))..seedDefaultCategories();
    w = l.createAccount(id: 'w', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 100);
  });

  test('update account; currency locked once used; archive/unarchive', () {
    final a = l.updateAccount(w.id, name: '微信钱包', type: AccountType.bank, initialBalanceMinor: 500, currency: 'USD');
    expect(a.name, '微信钱包');
    expect(a.currency, 'USD');
    expect(l.balance(w.id).minor, 500);
    l.updateAccount(w.id, currency: 'CNY');
    l.commit(l.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 1, 'currency': 'CNY', 'account_id': w.id, 'category_id': 'food', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.manual).single.id);
    expect(() => l.updateAccount(w.id, currency: 'USD'), throwsA(isA<InvalidStateException>()));
    l.archiveAccount(w.id);
    expect(l.listAccounts(), isEmpty);
    l.unarchiveAccount(w.id);
    expect(l.listAccounts().length, 1);
    expect(() => l.unarchiveAccount(w.id), throwsA(isA<InvalidStateException>()));
    expect(l.changes.pending().where((c) => c.entity == 'account').length, greaterThanOrEqualTo(5));
  });

  test('update category: rename, move, cycle/kind guards', () {
    final coffee = l.createCategory(id: 'coffee', name: '咖啡', kind: CategoryKind.expense, parentId: 'food');
    final latte = l.createCategory(id: 'latte', name: '拿铁', kind: CategoryKind.expense, parentId: 'coffee');
    expect(l.updateCategory(coffee.id, name: '咖啡饮品').name, '咖啡饮品');
    expect(l.updateCategory(coffee.id, parentId: 'daily').parentId, 'daily');
    expect(l.updateCategory(coffee.id, clearParent: true).parentId, isNull);
    expect(() => l.updateCategory(coffee.id, parentId: latte.id), throwsA(isA<ValidationException>())); // 挪到自己子孙下
    expect(() => l.updateCategory(coffee.id, parentId: coffee.id), throwsA(isA<ValidationException>()));
    expect(() => l.updateCategory(coffee.id, parentId: 'salary'), throwsA(isA<ValidationException>()));
    expect(() => l.updateCategory(coffee.id, name: ' '), throwsA(isA<ValidationException>()));
  });

  test('delete category refuses when referenced, names the users', () {
    l.createCategory(id: 'coffee', name: '咖啡', kind: CategoryKind.expense, parentId: 'food');
    l.createCategory(id: 'latte', name: '拿铁', kind: CategoryKind.expense, parentId: 'coffee');
    expect(() => l.deleteCategory('coffee'), throwsA(isA<InvalidStateException>().having((e) => e.message, 'msg', contains('subcategories'))));
    l.deleteCategory('latte');
    l.commit(l.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 1, 'currency': 'CNY', 'account_id': w.id, 'category_id': 'coffee', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.manual).single.id);
    expect(() => l.deleteCategory('coffee'), throwsA(isA<InvalidStateException>().having((e) => e.message, 'msg', contains('transactions'))));
    expect(() => l.deleteCategory('food'), throwsA(isA<InvalidStateException>()));
    expect(l.changes.pending().any((c) => c.entity == 'category' && c.entityId == 'latte' && c.deleted), isTrue);
  });
}
