import 'dart:convert';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 换设备：JSON 完整备份 → 新设备恢复，负债 / 信用卡条款 / 定期 / 目标 / 周期账单 / 预算 / 发薪日 一样不少。
void main() {
  test('JSON 备份往返：除了交易，负债、信用卡、定期、目标、周期、预算、画像都在', () {
    final a = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 10, 10, 4))..seedDefaultCategories();
    a.createAccount(id: 'bank', name: '工商银行', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 2000000);
    a.debts.add(name: '车贷', kind: DebtKind.car, owedMinor: 2600000, monthlyMinor: 260000, day: 15, fromAccountId: 'bank', today: '2026-10-10');
    a.cards.add(name: '花呗', terms: CreditProduct.huabei.defaults(limitMinor: 800000).copyWith(statementDay: 5, dueDay: 15), owedMinor: 30000);
    Setups(a).apply([SetupItem(kind: SetupKind.asset, name: '工行定期', assetType: AccountType.investment, deposit: true, principalMinor: 1000000, maturity: '2027-03-15', ratePercent: 2.1)], env: SetupEnv.of(a, today: '2026-10-10'));
    a.goals.create(kind: GoalKind.wish, name: '换手机', targetMinor: 699900, emoji: '📱', currency: 'CNY');
    a.budgets.create(name: '餐饮', categoryId: 'food', amountMinor: 200000, startDate: '2026-10-01');
    a.profile.set(ProfileStore.keyPayday, '10');

    final json = jsonDecode(exportJsonString(a)) as Map<String, Object?>;
    final b = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 10, 10, 4));
    restoreFromJson(b, json);

    String names(Ledger l) => (l.listAccounts(includeArchived: true, includeVault: true).map((x) => '${x.name}:${x.type.db}:${x.initialBalanceMinor}').toList()..sort()).join('|');
    expect(names(b), names(a));
    expect(b.debts.totals(today: '2026-10-10').totalMinor, a.debts.totals(today: '2026-10-10').totalMinor);
    final huabei = b.listAccounts().firstWhere((x) => x.name == '花呗');
    expect(b.cards.terms(huabei.id)?.dueDay, 15);
    final dep = b.listAccounts().firstWhere((x) => x.name == '工行定期');
    expect(DepositTerms.read(b, dep.id)?.maturity, '2027-03-15');
    expect(b.goals.list(activeOnly: false).map((g) => g.name).toSet(), a.goals.list(activeOnly: false).map((g) => g.name).toSet());
    expect(b.recurring.list(activeOnly: false).length, a.recurring.list(activeOnly: false).length);
    expect(b.budgets.list(activeOnly: false).length, 1);
    expect(b.profile.getString(ProfileStore.keyPayday), '10');
    expect(Wealth(b).compute(today: '2026-10-10').netWorthMinor, Wealth(a).compute(today: '2026-10-10').netWorthMinor);
  });

  test('认得出余见自己导出的明细表（导入前提醒「这个带不走信用卡 / 负债」）', () {
    final a = Ledger(openLedgerDatabaseInMemory())..seedDefaultCategories();
    expect(isYujianCsv(exportCsv(a)), isTrue);
    expect(isYujianCsv('微信支付账单明细\n交易时间,交易类型,交易对方,商品,收/支,金额(元)'), isFalse);
  });
}
