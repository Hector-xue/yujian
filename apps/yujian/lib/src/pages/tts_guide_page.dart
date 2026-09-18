import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 怎么开通短剧级配音：豆包语音（火山引擎）和 MiniMax 各一节，每步一个动作，只讲余见要填的那几样。
class TtsGuidePage extends StatelessWidget {
  const TtsGuidePage({super.key});

  Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget h(String t) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 6), child: Text(t, style: theme.textTheme.titleMedium));
    Widget p(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55)));
    Widget step(int n, String t, {String? url, String? urlLabel}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Text('$n', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
                  if (url != null)
                    InkWell(
                      onTap: () => _open(url),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(urlLabel ?? url, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, decoration: TextDecoration.underline)),
                      ),
                    ),
                ]),
              ),
            ],
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('怎么开通真人感配音')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('先说清楚', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(
                  '短剧配音、GPT 那种有情绪的声音，是云端大模型合成的，手机里跑不动。想要那个效果，得在厂商那里开通服务、拿一串密钥填进余见，按合成的字数付费——一个人日常听回复，一个月几毛到几块钱。\n'
                  '两家都行，选一家就够：豆包（抖音短剧同款，中文最自然）或 MiniMax。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                ),
              ]),
            ),
          ),
          h('豆包语音（火山引擎）—— 推荐'),
          step(1, '注册火山引擎账号并完成实名（企业或个人都行，个人用手机号 + 身份证）。', url: 'https://console.volcengine.com', urlLabel: 'console.volcengine.com'),
          step(2, '控制台顶部搜索「豆包语音」（也叫「语音技术」），进入后找「语音合成大模型」→ 开通。新账号有一份免费试用额度，够听很久。', url: 'https://console.volcengine.com/speech', urlLabel: 'console.volcengine.com/speech'),
          step(3, '左侧「应用管理」→ 创建一个应用（名字随便起，比如"余见"），勾上「语音合成大模型」。'),
          step(4, '拿密钥：新版控制台在应用里直接有「API Key」，复制它；老版控制台给的是「App ID」和「Access Token」两样，也行。'),
          step(5, '回到余见：更多 → 语音 → 选「豆包语音」，粘贴 API Key（老账号点「高级」填 App ID + Access Token），挑个音色，点「试听当前选的」。'),
          p('试听报「鉴权失败」多半是两种：key 复制少了字符，或第 2 步的服务没开通。报「invalid speaker」是音色没开通——2.0 音色要在控制台的音色列表里点「开通」（免费）。'),
          h('MiniMax'),
          step(1, '注册 MiniMax 开放平台，完成实名。', url: 'https://platform.minimaxi.com', urlLabel: 'platform.minimaxi.com'),
          step(2, '左侧「账户管理」→「接口密钥」→ 创建，复制 key。新账号有赠送额度。', url: 'https://platform.minimaxi.com/user-center/basic-information/interface-key', urlLabel: 'platform.minimaxi.com → 接口密钥'),
          step(3, '回到余见：更多 → 语音 → 选「MiniMax」，粘贴 API Key，挑个音色，试听。老账号如果报错提示要 GroupId，点「高级」填上（在「账户信息」页能看到）。'),
          h('语气'),
          p('语音页有一栏「语气（可选）」，写一句话就行，比如"用撒娇甜蜜的语气"、"沉稳一点"。豆包会照着念；MiniMax 只认几种情绪（开心 / 伤心 / 生气 / 平静……），会从你写的话里挑最接近的。'),
          h('花了多少'),
          p('更多 → 用量与花费里能看到合成了多少字；单价两家官网都有，点那一行可以自己填进去算钱。'),
        ],
      ),
    );
  }
}
