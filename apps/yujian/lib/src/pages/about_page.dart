import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../theme.dart';
import '../version.dart';
import 'feedback_page.dart';
import 'privacy_statement_page.dart';
import 'support_page.dart';

/// 门户地址（安装包 / 教程 / 更新日志）。
const homepageUrl = 'https://yujian.ivyea.com/';

/// 关于余见：这是什么、开源免费、账本不出手机、谁在做、源码在哪、怎么反馈 / 支持。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打不开：$url')));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    Widget point(IconData icon, String title, String sub) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(sub, style: theme.textTheme.bodySmall?.copyWith(height: 1.5)),
              ]),
            ),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('关于余见')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('余见', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 2),
                Text('版本 $appVersion', style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                Text('一个本地优先的 AI 记账助手：说一句话记一笔，付完款自动记上，把「可花的」「够花几个月」「怎么还款」算清楚给你看。', style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          point(Icons.lock_open_outlined, '开源、免费、没有广告', '源码按 AGPL-3.0 公开，任何人都能逐行查、自己编译；所有功能免费，没有会员、没有广告、没有内购。'),
          point(Icons.phone_android_outlined, '账本只在你手机上', '没有统计、埋点、广告 SDK。只有你自己配的模型 / 语音服务和你主动发的反馈会出网，每一次都记在「出网记录」里。'),
          point(Icons.person_outline, '一个人在做', '余见是一个人写的，按大家的反馈一点点改。遇到问题或者想要什么功能，直接在下面发反馈，作者会看到。'),
          const SizedBox(height: 4),
          GlassCard(
            child: Column(children: [
              ListTile(leading: const Icon(Icons.bug_report_outlined), title: const Text('反馈 BUG / 建议'), subtitle: const Text('可以带截图'), trailing: const Icon(Icons.chevron_right), onTap: () => go(const FeedbackPage())),
              const Divider(indent: 16, endIndent: 16),
              ListTile(leading: const Icon(Icons.favorite_border), title: const Text('支持余见'), subtitle: Text(app.isSupporter ? '已支持 · 谢谢' : '¥1 · 不付也一样用'), trailing: const Icon(Icons.chevron_right), onTap: () => go(const SupportPage())),
              const Divider(indent: 16, endIndent: 16),
              ListTile(leading: const Icon(Icons.code), title: const Text('源码'), subtitle: const Text(sourceRepoUrl), trailing: const Icon(Icons.open_in_new, size: 18), onTap: () => _open(context, sourceRepoUrl)),
              const Divider(indent: 16, endIndent: 16),
              ListTile(leading: const Icon(Icons.public), title: const Text('官网'), subtitle: const Text('下载、教程、更新日志'), trailing: const Icon(Icons.open_in_new, size: 18), onTap: () => _open(context, homepageUrl)),
              const Divider(indent: 16, endIndent: 16),
              ListTile(leading: const Icon(Icons.privacy_tip_outlined), title: const Text('隐私声明'), trailing: const Icon(Icons.chevron_right), onTap: () => go(const PrivacyStatementPage())),
            ]),
          ),
          const SizedBox(height: 12),
          Text('AGPL-3.0 · 你可以自由使用、修改、分发；改了拿去提供服务也要公开源码。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
        ],
      ),
    );
  }
}
