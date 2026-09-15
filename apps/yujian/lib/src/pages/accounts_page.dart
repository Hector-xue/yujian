import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../widgets/fmt.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  static const _typeLabels = {
    AccountType.cash: '现金',
    AccountType.bank: '银行卡',
    AccountType.creditCard: '信用卡',
    AccountType.eWallet: '电子钱包',
    AccountType.receivable: '应收',
    AccountType.payable: '应付',
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: Text(a.name, style: a.isArchived ? TextStyle(color: theme.textTheme.bodySmall?.color) : null),
          subtitle: Text('${_typeLabels[a.type] ?? a.type.db}${a.currency != 'CNY' ? ' · ${a.currency}' : ''}', style: theme.textTheme.bodySmall),
          trailing: Text(fmtMoney(app.ledger.balance(a.id).minor, a.currency), style: theme.textTheme.titleMedium),
          onTap: () => _edit(context, a),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('账户'), actions: [IconButton(onPressed: () => _add(context), icon: const Icon(Icons.add))]),
      body: ListView(
        children: [
          for (final a in active) tile(a),
          if (archived.isNotEmpty) ...[
            Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 4), child: Text('已归档', style: theme.textTheme.bodySmall)),
            for (final a in archived) tile(a),
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
    final hasPostings = app.ledger.listTransactions(accountId: a.id, limit: 1).isNotEmpty;
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
              DropdownButtonFormField<AccountType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: '类型'),
                items: [for (final e in _typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              TextField(controller: initial, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: '期初余额（${a.currency}）', helperText: hasPostings ? '币种已有交易，不能改' : null)),
            ],
          ),
          actions: [
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
          app.ledger.archiveAccount(a.id);
        case 'unarchive':
          app.ledger.unarchiveAccount(a.id);
        case 'save':
          app.ledger.updateAccount(a.id, name: name.text.trim(), type: type, initialBalanceMinor: Money.parse(initial.text.trim().isEmpty ? '0' : initial.text.trim(), a.currency).minor);
      }
      app.touch();
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
              DropdownButtonFormField<AccountType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: '类型'),
                items: [for (final e in _typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: currency,
                decoration: const InputDecoration(labelText: '币种'),
                items: [for (final c in const ['CNY', 'USD', 'HKD', 'JPY', 'EUR', 'GBP', 'TWD', 'SGD', 'AUD', 'CAD']) DropdownMenuItem(value: c, child: Text(c))],
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
