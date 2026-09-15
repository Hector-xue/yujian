import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import 'accounts_page.dart';
import 'categories_page.dart';
import 'data_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    Widget item(IconData icon, String title, Widget page) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right, color: Color(0xFFB0B7B3)),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListView(
        children: [
          item(Icons.bar_chart_outlined, '月度统计', const StatsPage()),
          item(Icons.account_balance_wallet_outlined, '账户', const AccountsPage()),
          item(Icons.label_outline, '分类', const CategoriesPage()),
          item(Icons.history, '审计日志', const _AuditPage()),
          item(Icons.import_export, '数据：导出 / 备份 / 导入', const DataPage()),
          const Divider(),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.tune, color: theme.colorScheme.primary),
            title: const Text('模型与人格'),
            subtitle: Text(app.hasModel ? '${app.settings.model} · ${app.persona.name}' : '未配置模型（规则解析） · ${app.persona.name}', style: theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right, color: Color(0xFFB0B7B3)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Text('余见 0.1.0 · 本地账本 · ${app.ledger.listTransactions(limit: 100000).length} 笔记录', style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _AuditPage extends StatelessWidget {
  const _AuditPage();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final log = app.ledger.auditLog(limit: 200);
    return Scaffold(
      appBar: AppBar(title: const Text('审计日志')),
      body: ListView(
        children: [
          for (final e in log)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text('${e.action}${e.confirmedByUser ? ' ✓' : ''}'),
              subtitle: Text('${e.at.toLocal().toIso8601String().substring(0, 19).replaceAll('T', ' ')} · ${e.actor.db}${e.modelUsed != null ? ' · ${e.modelUsed}' : ''}', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
