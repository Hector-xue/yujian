import 'package:flutter/material.dart';

import '../app_state.dart';
import '../db/open_db.dart';
import '../theme.dart';
import '../update/update_sheet.dart';
import '../version.dart';
import '../widgets/fmt.dart';
import 'accounts_page.dart';
import 'ai_page.dart';
import 'appearance_page.dart';
import 'audit_page.dart';
import 'automation_page.dart';
import 'budgets_page.dart';
import 'calendar_page.dart';
import 'categories_page.dart';
import 'data_page.dart';
import 'debts_page.dart';
import 'goals_page.dart';
import '../local_model/lab_page.dart';
import 'persona_page.dart';
import 'privacy_page.dart';
import 'recurring_page.dart';
import 'stats_page.dart';
import 'sync_page.dart';
import 'tasks_page.dart';
import 'wealth_page.dart';
import 'widgets_page.dart';

/// 更多：按「记账 / 自动化 / AI / 隐私 / 外观 / 数据 / 关于」分组，每组一张卡。模型相关只留一个入口（模型与语音）。
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    Widget item(IconData icon, String title, {String? subtitle, Widget? trailing, required VoidCallback onTap, VoidCallback? onLongPress}) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: trailing ?? Icon(Icons.chevron_right, color: muted),
          onTap: onTap,
          onLongPress: onLongPress,
        );
    Widget group(String title, List<Widget> items) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 6), child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: muted))),
            GlassCard(
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
    final modelLine = s.offlineMode
        ? '纯本地模式，不调模型'
        : app.hasModel
            ? '${s.model}${(s.visionModel ?? '').isNotEmpty ? ' · 看图 ${s.visionModel}' : ''}'
            : '未配置，用规则解析';
    final voiceLine = switch (s.effectiveSpeechEngine) { 'doubao' => '豆包语音', 'minimax' => 'MiniMax', 'cloud' => '云端 ${s.speechModel ?? ''}', 'omni' => '主模型自带语音', _ => '系统朗读' };
    final upd = app.availableUpdate;

    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListenableBuilder(
        listenable: app.game,
        builder: (context, _) => ListView(
        padding: EdgeInsets.only(top: 4, bottom: 8 + MediaQuery.paddingOf(context).bottom), // 底栏悬浮在页面上，最后一项要留出它的高度
        children: [
          group('目标', [
            item(Icons.flag_outlined, '目标', subtitle: app.game.goals.isEmpty ? '换手机 / 买车 / 首付 / 旅行——给钱一个用途' : app.game.goals.take(2).map((p) => '${p.goal.name} ${(p.ratio * 100).toStringAsFixed(0)}%').join(' · '), onTap: () => go(const GoalsPage())),
            item(Icons.task_alt_outlined, '周任务', subtitle: app.game.weekTasks.isEmpty ? '本周还没挑' : '本周 ${app.game.weekTasks.length} 个', onTap: () => go(const TasksPage())),
            item(Icons.insights_outlined, '财富', subtitle: app.game.metrics?.title == null ? '可花的 · 等级 · 成就' : '「${app.game.metrics!.title}」· 可花的 ${fmtMoney(app.game.metrics!.disposableMinor, 'CNY')}', onTap: () => go(const WealthPage())),
          ]),
          group('记账', [
            item(Icons.bar_chart_outlined, '月度统计', onTap: () => go(const StatsPage())),
            item(Icons.calendar_month_outlined, '日历', onTap: () => go(const CalendarPage())),
            item(Icons.savings_outlined, '预算', onTap: () => go(const BudgetsPage())),
            item(Icons.event_repeat_outlined, '周期账单', onTap: () => go(const RecurringPage())),
            item(Icons.account_balance_wallet_outlined, '账户', onTap: () => go(const AccountsPage())),
            item(Icons.credit_score_outlined, '负债', subtitle: app.game.metrics == null || app.game.metrics!.debt.totalMinor <= 0 ? '房贷 / 车贷 / 网贷——填两个数，还款提醒和还清目标自动建' : '总负债 ${fmtMoney(app.game.metrics!.debt.totalMinor, 'CNY')}${app.game.metrics!.debt.monthlyMinor > 0 ? ' · 每月还 ${fmtMoney(app.game.metrics!.debt.monthlyMinor, 'CNY')}' : ''}', onTap: () => go(const DebtsPage())),
            item(Icons.label_outline, '分类', onTap: () => go(const CategoriesPage())),
          ]),
          group('自动化', [
            item(Icons.notifications_active_outlined, '自动记账', subtitle: '通知 / 支付页 / 截图，三条路', onTap: () => go(const AutomationPage())),
            item(Icons.widgets_outlined, '桌面小部件', onTap: () => go(const WidgetsPage())),
          ]),
          group('AI', [
            item(Icons.tune, '模型与语音', subtitle: '$modelLine · $voiceLine', onTap: () => go(const AiPage())),
            item(Icons.face_outlined, '人格与角色', subtitle: app.persona.name, onTap: () => go(const PersonaPage())),
            item(Icons.memory_outlined, '本地模型（打样）', subtitle: '下载 Qwen3.5 小模型在手机上跑一遍，看耗时和内存', onTap: () => go(const LocalModelLabPage())),
          ]),
          group('隐私', [
            item(
              Icons.shield_outlined,
              '隐私',
              subtitle: s.offlineMode ? '纯本地模式已开 · 无任何数据出手机' : '纯本地模式 · 出网记录 · 隐私声明 · 权限教程',
              trailing: s.offlineMode ? Icon(Icons.lock_outline, color: theme.colorScheme.primary) : null,
              onTap: () => go(const PrivacyPage()),
            ),
          ]),
          group('外观', [
            item(Icons.palette_outlined, '主题', subtitle: themeById(s.themeId).name, onTap: () => go(const AppearancePage())),
          ]),
          group('数据', [
            item(Icons.import_export, '导出 / 备份 / 导入', onTap: () => go(const DataPage())),
            item(Icons.sync_outlined, '同步与云备份', subtitle: s.syncConfigured ? '已配置' : '未配置', onTap: () => go(const SyncPage())),
            item(Icons.history, '审计日志', subtitle: '账本每一次改动', onTap: () => go(const AuditPage())),
          ]),
          group('关于', [
            item(
              Icons.system_update_alt_outlined,
              '检查更新',
              subtitle: upd != null ? '有新版本 ${upd.version}' : '当前 $appVersion',
              trailing: upd != null ? Badge(label: const Text('新'), child: Icon(Icons.chevron_right, color: muted)) : null,
              // 长按：显示 / 隐藏性能层（每帧耗时条），卡顿时截个图就能定位是 UI 线程还是 GPU
              onLongPress: () {
                app.togglePerfOverlay();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.perfOverlay ? '性能层已开：上面一条是 GPU，下面一条是 UI 线程，绿线以上就是掉帧' : '性能层已关')));
              },
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
            child: SelectableText('余见 $appVersion · 本地账本 · ${app.ledger.countTransactions()} 笔记录\n${appDatabasePath ?? ''}', style: theme.textTheme.bodySmall),
          ),
        ],
        ),
      ),
    );
  }
}
