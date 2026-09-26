import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';
import '../errors_zh.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  static const _typeLabels = {
    AccountType.cash: '现金',
    AccountType.bank: '银行卡',
    AccountType.creditCard: '信用卡',
    AccountType.eWallet: '电子钱包',
    AccountType.receivable: '借出去的',
    AccountType.payable: '贷款 / 借款',
    AccountType.investment: '投资',
  };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final all = app.ledger.listAccounts(includeArchived: true);
    final active = all.where((a) => !a.isArchived).toList();
    final archived = all.where((a) => a.isArchived).toList();
    Widget tile(Account a) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(a.name, style: a.isArchived ? TextStyle(color: theme.textTheme.bodySmall?.color) : null),
          subtitle: Text('${_typeLabels[a.type] ?? a.type.db}${a.currency != 'CNY' ? ' · ${a.currency}' : ''}${!a.isArchived && app.defaultAccountId == a.id ? ' · 默认记账' : ''}', style: theme.textTheme.bodySmall),
          trailing: Text(fmtMoney(app.ledger.balance(a.id).minor, a.currency), style: theme.textTheme.titleMedium),
          onTap: () => _edit(context, a),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('账户'), actions: [IconButton(tooltip: '添加账户', onPressed: () => _add(context), icon: const Icon(Icons.add))]),
      // 在用的一张卡、归档的一张卡；空着就给一句话
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (active.isEmpty)
            Padding(padding: const EdgeInsets.all(12), child: Text('还没有账户，点右上角加一个', style: theme.textTheme.bodySmall))
          else
            GlassCard(child: Column(children: [for (final a in active) tile(a)])),
          if (archived.isNotEmpty) ...[
            Padding(padding: const EdgeInsets.fromLTRB(2, 16, 2, 6), child: Text('已归档', style: theme.textTheme.bodySmall)),
            GlassCard(child: Column(children: [for (final a in archived) tile(a)])),
          ],
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, Account a) async {
    final app = AppScope.of(context);
    final name = TextEditingController(text: a.name);
    final initial = TextEditingController(text: Money(a.initialBalanceMinor, a.currency).toDecimalString());
    var type = a.type;
    final wasDefault = app.defaultAccountId == a.id;
    var makeDefault = wasDefault;
    final hasPostings = app.ledger.accountPostingCount(a.id) > 0;
    final result = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: Text(a.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称')),
              const SizedBox(height: 12),
              PickerField<AccountType>(
                value: type,
                decoration: const InputDecoration(labelText: '类型'),
                items: [for (final e in _typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: initial,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: InputDecoration(labelText: '期初余额（${a.currency}）', helperText: hasPostings ? '币种已有交易，不能改' : null)),
              if (!a.isArchived)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('默认记账账户'),
                  subtitle: const Text('一句话记账、通知认不出账户时都记到这里'),
                  value: makeDefault,
                  onChanged: (v) => setState(() => makeDefault = v),
                ),
              if (hasPostings) ...[
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: Text('已有交易的账户只能归档，删了历史就对不上。', style: Theme.of(d).textTheme.bodySmall)),
              ],
            ],
          ),
          actions: [
            if (!hasPostings)
              TextButton(
                onPressed: () => Navigator.pop(d, 'delete'),
                style: TextButton.styleFrom(foregroundColor: Theme.of(d).colorScheme.error),
                child: const Text('删除'),
              ),
            TextButton(onPressed: () => Navigator.pop(d, a.isArchived ? 'unarchive' : 'archive'), child: Text(a.isArchived ? '恢复' : '归档')),
            TextButton(onPressed: () => Navigator.pop(d, null), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, 'save'), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    try {
      switch (result) {
        case 'archive':
          // 还有钱 / 还有周期账单在用它：先说清楚后果再归档
          final bal = app.ledger.balance(a.id).minor;
          final using = app.ledger.recurringUsing(a.id);
          if (bal != 0 || using.isNotEmpty) {
            final sure = await showDialog<bool>(
              context: context,
              builder: (dlg) => AlertDialog(
                title: Text('归档「${a.name}」？'),
                content: Text([
                  if (bal != 0) '账户里还有 ${fmtMoney(bal, a.currency)}：归档后不再算进余额和净资产。钱没有消失，只是不统计了；卡已经不用了的话，先把钱转走或把余额调成 0。',
                  if (using.isNotEmpty) '用它的周期账单会一起停掉：${using.map((r) => r.name).join('、')}。恢复账户后到「周期账单」里重新打开。',
                ].join('\n\n')),
                actions: [TextButton(onPressed: () => Navigator.pop(dlg, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(dlg, true), child: const Text('归档'))],
              ),
            );
            if (sure != true || !context.mounted) return;
          }
          final paused = app.ledger.archiveAccount(a.id);
          if (paused > 0) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已归档，停掉了 $paused 条周期账单')));
        case 'unarchive':
          app.ledger.unarchiveAccount(a.id);
        case 'delete':
          final sure = await showDialog<bool>(
            context: context,
            builder: (dlg) => AlertDialog(
              title: Text('删除账户「${a.name}」？'),
              content: const Text('这个账户没有任何交易记录，删了就没了。'),
              actions: [TextButton(onPressed: () => Navigator.pop(dlg, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(dlg, true), child: const Text('删除'))],
            ),
          );
          if (sure != true || !context.mounted) return;
          if (Debts.isLiability(a.type)) {
            app.removeDebt(a.id); // 负债账户连还款提醒和还清目标一起清，否则目标还挂着它删不掉
          } else {
            app.deleteAccount(a.id);
          }
        case 'save':
          app.ledger.updateAccount(a.id, name: name.text.trim(), type: type, initialBalanceMinor: Money.parse(initial.text.trim().isEmpty ? '0' : initial.text.trim(), a.currency).minor);
          if (makeDefault != wasDefault) app.setDefaultAccount(makeDefault ? a.id : null);
      }
      app.touch();
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _add(BuildContext context) async {
    final app = AppScope.of(context);
    final name = TextEditingController();
    final initial = TextEditingController(text: '0');
    var type = AccountType.bank;
    var currency = 'CNY';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: const Text('新账户'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称'), autofocus: true),
              const SizedBox(height: 12),
              PickerField<AccountType>(
                value: type,
                decoration: const InputDecoration(labelText: '类型'),
                items: [for (final e in _typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              PickerField<String>(
                value: currency,
                decoration: const InputDecoration(labelText: '币种'),
                items: [
                  for (final c in const ['CNY', 'USD', 'HKD', 'JPY', 'EUR', 'GBP', 'TWD', 'SGD', 'AUD', 'CAD']) DropdownMenuItem(value: c, child: Text(c))
                ],
                onChanged: (v) => setState(() => currency = v ?? currency),
              ),
              const SizedBox(height: 12),
              TextField(controller: initial, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: '当前余额')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('添加')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      app.addAccount(name: name.text.trim(), type: type, currency: currency, initialBalanceMinor: Money.parse(initial.text.trim().isEmpty ? '0' : initial.text.trim(), currency).minor);
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }
}
