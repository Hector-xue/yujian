import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../db/open_db.dart';
import '../theme.dart';
import '../update/update_sheet.dart';
import '../version.dart';
import 'accounts_page.dart';
import 'api_guide_page.dart';
import 'appearance_page.dart';
import 'automation_page.dart';
import 'budgets_page.dart';
import 'calendar_page.dart';
import 'categories_page.dart';
import 'data_page.dart';
import 'model_page.dart';
import 'persona_page.dart';
import 'recurring_page.dart';
import 'stats_page.dart';
import 'sync_page.dart';
import 'usage_page.dart';
import 'voice_page.dart';
import 'widgets_page.dart';

/// 更多：按「记账 / 自动化 / AI 与语音 / 外观 / 数据 / 关于」分组，每组一张卡。
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    Widget item(IconData icon, String title, {String? subtitle, Widget? trailing, required VoidCallback onTap}) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: trailing ?? Icon(Icons.chevron_right, color: muted),
          onTap: onTap,
        );
    Widget group(String title, List<Widget> items) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 6), child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: muted))),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(indent: 56),
                  items[i],
                ],
              ]),
            ),
          ]),
        );

    final s = app.settings;
    final modelLine = app.hasModel ? '${s.model}${(s.visionModel ?? '').isNotEmpty ? ' · 看图 ${s.visionModel}' : ''}' : '未配置，用规则解析';
    final voiceLine = (s.speechModel ?? '').isNotEmpty ? '云端合成 ${s.speechModel}' : '系统朗读；可装离线包或配云端';
    final upd = app.availableUpdate;

    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        children: [
          group('记账', [
            item(Icons.bar_chart_outlined, '月度统计', onTap: () => go(const StatsPage())),
            item(Icons.calendar_month_outlined, '日历', onTap: () => go(const CalendarPage())),
            item(Icons.savings_outlined, '预算', onTap: () => go(const BudgetsPage())),
            item(Icons.event_repeat_outlined, '周期账单', onTap: () => go(const RecurringPage())),
            item(Icons.account_balance_wallet_outlined, '账户', onTap: () => go(const AccountsPage())),
            item(Icons.label_outline, '分类', onTap: () => go(const CategoriesPage())),
          ]),
          group('自动化', [
            item(Icons.notifications_active_outlined, '自动记账', subtitle: '通知 / 支付页 / 截图，三条路', onTap: () => go(const AutomationPage())),
            item(Icons.widgets_outlined, '桌面小部件', onTap: () => go(const WidgetsPage())),
          ]),
          group('AI 与语音', [
            item(Icons.tune, '模型与 API', subtitle: modelLine, onTap: () => go(const ModelPage())),
            item(Icons.help_outline, '怎么申请 API', subtitle: '拿 DeepSeek、硅基流动举例，看完能一键填入', onTap: () => go(const ApiGuidePage())),
            item(Icons.data_usage_outlined, '用量与花费', subtitle: _usageLine(app), onTap: () => go(const UsagePage())),
            item(Icons.mic_none, '语音', subtitle: voiceLine, onTap: () => go(const VoicePage())),
            item(Icons.face_outlined, '人格与角色', subtitle: app.persona.name, onTap: () => go(const PersonaPage())),
          ]),
          group('外观', [
            item(Icons.palette_outlined, '主题', subtitle: themeById(s.themeId).name, onTap: () => go(const AppearancePage())),
          ]),
          group('数据', [
            item(Icons.import_export, '导出 / 备份 / 导入', onTap: () => go(const DataPage())),
            item(Icons.sync_outlined, '同步与云备份', subtitle: s.syncConfigured ? '已配置' : '未配置', onTap: () => go(const SyncPage())),
            item(Icons.history, '审计日志', onTap: () => go(const _AuditPage())),
          ]),
          group('关于', [
            item(
              Icons.system_update_alt_outlined,
              '检查更新',
              subtitle: upd != null ? '有新版本 ${upd.version}' : '当前 $appVersion',
              trailing: upd != null ? Badge(label: const Text('新'), child: Icon(Icons.chevron_right, color: muted)) : null,
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final r = await app.checkUpdate(force: true);
                if (!context.mounted) return;
                if (r == null) {
                  messenger.showSnackBar(const SnackBar(content: Text('已经是最新版')));
                } else {
                  await showUpdateSheet(context, r, onSkip: () => app.skipUpdate(r.version));
                }
              },
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: SelectableText('余见 $appVersion · 本地账本 · ${app.ledger.listTransactions(limit: 100000).length} 笔记录\n${appDatabasePath ?? ''}', style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  static String _usageLine(AppState app) {
    final n = DateTime.now();
    final m = app.usage.summary(from: DateTime(n.year, n.month, 1));
    if (m.tokens == 0 && m.chars == 0) return '本月还没用过模型';
    return '本月 ${fmtTokens(m.tokens)} token · 约 ¥${m.knownCost.toStringAsFixed(2)}${m.unknownModels.isEmpty ? '' : '+?'}';
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
              subtitle:
                  Text('${e.at.toLocal().toIso8601String().substring(0, 19).replaceAll('T', ' ')} · ${e.actor.db}${e.modelUsed != null ? ' · ${e.modelUsed}' : ''}', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
