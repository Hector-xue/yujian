import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'audit_page.dart';
import 'automation_guide_page.dart';
import 'net_log_page.dart';
import 'privacy_statement_page.dart';

/// 隐私：纯本地模式一键开关（禁掉一切出网路径）、出网记录、隐私声明、脱敏开关、自动记账权限教程。
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    final s = app.settings;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    final today = DateTime.now();
    final todayCount = app.netLog.countSince(DateTime(today.year, today.month, today.day));
    final last = app.netLog.last;

    // 开了纯本地模式会被挡掉的东西，按当前配置列出来，让人知道开关到底关了什么
    final blocked = <String>[
      if (s.modelFilled) '模型「${s.model}」（对话记账 / 查询 / 陪聊 / 看图）',
      if ((s.transcribeModel ?? '').isNotEmpty) '云端语音转写',
      if (s.speechEngine != 'system') '云端语音合成（改用系统朗读）',
      if (s.screenshotMode != 'local') '截图自动记账的「发文字 / 发原图」档（改为仅本机）',
      if (s.syncConfigured) '同步与云备份',
      '每天一次的自动版本检查',
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('隐私')),
      body: ListenableBuilder(
        listenable: app.netLog,
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('纯本地模式'),
                    subtitle: Text(s.offlineMode ? '已开。没有任何数据会和外界交互：只用本机识别、本机规则。' : '一键禁用所有可能把数据发出手机的功能，只用本机识别和本机规则。', style: theme.textTheme.bodySmall),
                    value: s.offlineMode,
                    onChanged: (v) async {
                      await app.setOfflineMode(v);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(v ? '纯本地模式已开：模型 / 云端语音 / 同步 / 自动版本检查全部停用，配置保留' : '纯本地模式已关：按你的配置恢复')));
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      s.offlineMode
                          ? '现在会被挡住的：${blocked.join('；')}。配置都还在，关掉这个开关就恢复。你手动点的「检查更新」和下载离线语音包仍然可用（只下载，不上传）。'
                          : '打开后会停用：${blocked.join('；')}。记账、查询、统计、通知 / 支付页 / 截图（仅本机档）自动记账、离线语音识别、系统朗读都照常。',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                ListTile(
                  leading: Icon(Icons.public, color: theme.colorScheme.primary),
                  title: const Text('出网记录'),
                  subtitle: Text(
                    last == null ? '还没有任何对外通信' : '今天 $todayCount 次 · 最近：${last.title}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Icon(Icons.chevron_right, color: muted),
                  onTap: () => go(const NetLogPage()),
                ),
                const Divider(indent: 56),
                ListTile(
                  leading: Icon(Icons.history, color: theme.colorScheme.primary),
                  title: const Text('审计日志'),
                  subtitle: Text('账本的每一次改动，谁改的、有没有经你确认', style: theme.textTheme.bodySmall),
                  trailing: Icon(Icons.chevron_right, color: muted),
                  onTap: () => go(const AuditPage()),
                ),
                const Divider(indent: 56),
                ListTile(
                  leading: Icon(Icons.privacy_tip_outlined, color: theme.colorScheme.primary),
                  title: const Text('隐私声明'),
                  subtitle: Text('哪些数据会出手机、哪些不会、每个权限干什么、怎么核对', style: theme.textTheme.bodySmall),
                  trailing: Icon(Icons.chevron_right, color: muted),
                  onTap: () => go(const PrivacyStatementPage()),
                ),
                const Divider(indent: 56),
                ListTile(
                  leading: Icon(Icons.menu_book_outlined, color: theme.colorScheme.primary),
                  title: const Text('自动记账设置教程'),
                  subtitle: Text('去哪开权限、开哪些、系统警告是什么意思', style: theme.textTheme.bodySmall),
                  trailing: Icon(Icons.chevron_right, color: muted),
                  onTap: () => go(const AutomationGuidePage()),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('发送前脱敏'),
                  subtitle: Text('发给模型之前，把卡号、手机号、身份证、订单号、邮箱换成占位符；金额不动。和「模型与语音」里是同一个开关', style: theme.textTheme.bodySmall),
                  value: s.redact,
                  onChanged: s.offlineMode ? null : (v) => app.saveSettings(s.copyWith(redact: v)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('余见没有自己的服务器接收数据；唯一的出口是你自己填的模型 / 语音服务，每一次都进出网记录。源码开源可查。', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
        ),
      ),
    );
  }
}
