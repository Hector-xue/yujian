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
    final accounts = app.accounts;
    return Scaffold(
      appBar: AppBar(title: const Text('账户'), actions: [IconButton(onPressed: () => _add(context), icon: const Icon(Icons.add))]),
      body: ListView(
        children: [
          for (final a in accounts)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(a.name),
              subtitle: Text(_typeLabels[a.type] ?? a.type.db, style: theme.textTheme.bodySmall),
              trailing: Text(fmtMoney(app.ledger.balance(a.id).minor, a.currency), style: theme.textTheme.titleMedium),
            ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final app = AppScope.of(context);
    final name = TextEditingController();
    final initial = TextEditingController(text: '0');
    var type = AccountType.bank;
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
              TextField(controller: initial, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: '当前余额（CNY）')),
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
      app.addAccount(name: name.text.trim(), type: type, currency: 'CNY', initialBalanceMinor: Money.parse(initial.text.trim().isEmpty ? '0' : initial.text.trim(), 'CNY').minor);
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
