import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'model_page.dart';

/// 一套可一键填入「模型与 API」页的配置。
class ApiPreset {
  final String name;
  final String providerType;
  final String baseUrl;
  final String model;
  final String? visionModel;
  /// 顺手把语音也配上：同一把 key 能用的转写 / 合成模型，以及朗读引擎（cloud = OpenAI 兼容合成，omni = 主模型自带语音）
  final String? transcribeModel;
  final String? speechModel;
  final String? speechVoice;
  final String? speechEngine;
  const ApiPreset({required this.name, this.providerType = 'openai', required this.baseUrl, required this.model, this.visionModel, this.transcribeModel, this.speechModel, this.speechVoice, this.speechEngine});
}

const deepseekPreset = ApiPreset(name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-flash');
const siliconflowPreset = ApiPreset(
  name: '硅基流动',
  baseUrl: 'https://api.siliconflow.cn/v1',
  model: 'deepseek-ai/DeepSeek-V3',
  visionModel: 'Qwen/Qwen3-VL-8B-Instruct',
  transcribeModel: 'FunAudioLLM/SenseVoiceSmall',
  speechModel: 'FunAudioLLM/CosyVoice2-0.5B',
  speechVoice: 'FunAudioLLM/CosyVoice2-0.5B:anna',
  speechEngine: 'cloud',
);
const bailianPreset = ApiPreset(name: '阿里云百炼 · Qwen-Omni', baseUrl: '', model: 'qwen3-omni-flash', speechEngine: 'omni');

/// 怎么申请 API：面向不知道"模型在哪买"的用户。两家举例，每步一个动作，末尾一键填入。
/// [asPicker] 从「模型与 API」页进来时为 true：选完直接把配置带回去，不再套一层页面。
class ApiGuidePage extends StatelessWidget {
  final bool asPicker;
  const ApiGuidePage({super.key, this.asPicker = false});

  Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  void _use(BuildContext context, ApiPreset p) {
    if (asPicker) {
      Navigator.of(context).pop(p);
    } else {
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ModelPage(preset: p)));
    }
  }

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
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            SizedBox(width: 92, child: Text(k, style: theme.textTheme.bodySmall)),
            Expanded(child: SelectableText(v, style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', fontSize: 13))),
            IconButton(
              tooltip: '复制',
              icon: const Icon(Icons.copy, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: v));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)));
              },
            ),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('怎么申请 API')),
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
                  '余见不配模型也能记账（规则解析）。配上模型后：说话更随意也能听懂、能看图识别截图、能陪你聊。\n'
                  '"模型"不是买软件，是按用量付费的接口：你在模型厂商那里注册、充几块钱、拿到一串 API Key，填进余见就行。一个人日常记账，一个月通常几毛到几块钱。\n'
                  '只需要配一个：现在的主流模型一个就能又读字又看图；语音想要更好再另选。下面三家挑一家。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                ),
              ]),
            ),
          ),
          h('三个概念'),
          p('Base URL：接口地址，厂商文档里写着，照抄。\nAPI Key：你的钥匙，一串 sk- 开头的字符，只在创建时显示一次，自己存好；余见只存在本机安全存储里。\n模型名：同一家有好几个模型，填名字告诉它用哪个；余见里点模型名右边的列表图标可以直接选，不用手打。'),

          h('例一：DeepSeek（官方，便宜、中文好）'),
          step(1, '打开 DeepSeek 开放平台，用手机号或邮箱注册、登录。', url: 'https://platform.deepseek.com', urlLabel: 'platform.deepseek.com'),
          step(2, '左侧「充值」，先充 10 元足够用很久（支持微信 / 支付宝）。'),
          step(3, '左侧「API keys」→「创建 API key」，起个名字（如"余见"），复制生成的 key。关掉后就看不到了，丢了重新建一个。', url: 'https://platform.deepseek.com/api_keys', urlLabel: 'platform.deepseek.com/api_keys'),
          step(4, '回到余见，填入下面这三项，点「测试连接」看到 ✓ 就成。'),
          kv('接口类型', 'OpenAI 兼容'),
          kv('Base URL', deepseekPreset.baseUrl),
          kv('模型名', deepseekPreset.model),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text('deepseek-flash 便宜、够用，V4.1 起也能看图；想要更强选 deepseek-v4-pro（贵几倍）。「测试连接」会实测看图能力，显示 ✗ 就另配一个看图模型（见例二）。价格看官网「模型 & 价格」页。', style: theme.textTheme.bodySmall),
          ),
          FilledButton.tonalIcon(onPressed: () => _use(context, deepseekPreset), icon: const Icon(Icons.input, size: 18), label: const Text('把 DeepSeek 的配置填进去')),

          h('例二：硅基流动（模型超市，一把钥匙用很多家模型）'),
          step(1, '打开硅基流动，手机号注册、登录。新用户通常送一点体验额度。', url: 'https://cloud.siliconflow.cn', urlLabel: 'cloud.siliconflow.cn'),
          step(2, '左侧「API 密钥」→「新建 API 密钥」，复制。', url: 'https://cloud.siliconflow.cn/account/ak', urlLabel: 'cloud.siliconflow.cn/account/ak'),
          step(3, '「模型广场」里能看到每个模型的价格，有一批小模型是免费的（如 Qwen/Qwen3-8B）。看图、语音识别、语音合成的模型这里也有。'),
          step(4, '回到余见，点下面按钮一次填全（文字 / 看图 / 语音识别 / 语音合成用同一把 key）：'),
          kv('接口类型', 'OpenAI 兼容'),
          kv('Base URL', siliconflowPreset.baseUrl),
          kv('模型名', siliconflowPreset.model),
          kv('看图模型', 'Qwen/Qwen3-VL-8B-Instruct'),
          kv('语音转写', 'FunAudioLLM/SenseVoiceSmall'),
          kv('语音合成', 'FunAudioLLM/CosyVoice2-0.5B'),
          kv('音色', 'FunAudioLLM/CosyVoice2-0.5B:anna'),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text('模型名以「模型广场」和余见里拉出来的列表为准，名字偶尔会变。看图 / 语音这几项是可选的，不填也能记账。', style: theme.textTheme.bodySmall),
          ),
          FilledButton.tonalIcon(onPressed: () => _use(context, siliconflowPreset), icon: const Icon(Icons.input, size: 18), label: const Text('把硅基流动的配置填进去')),

          h('例三：阿里云百炼 · Qwen-Omni（一个模型：文字 + 看图 + 说话）'),
          step(1, '注册阿里云并开通「百炼」（模型服务），完成实名。', url: 'https://bailian.console.aliyun.com', urlLabel: 'bailian.console.aliyun.com'),
          step(2, '左下角「API-KEY」→ 创建，复制。', url: 'https://bailian.console.aliyun.com/model/settings/api-key', urlLabel: 'bailian.console.aliyun.com → API-KEY'),
          step(3, '控制台首页会显示你的「接口地址」（形如 https://xxxx.cn-beijing.maas.aliyuncs.com/compatible-mode/v1，带你自己的工作空间 ID），复制它当 Base URL。'),
          step(4, '回到余见，点下面按钮填入，粘贴 Base URL 和 Key，模型名点右侧列表挑一个带 omni 的（如 qwen3-omni-flash）。它一个模型就能读字、看图、开口说话——语音页会自动选成「主模型自带语音」。'),
          FilledButton.tonalIcon(onPressed: () => _use(context, bailianPreset), icon: const Icon(Icons.input, size: 18), label: const Text('把百炼的配置填进去')),
          h('其他也行'),
          p('OpenAI、OpenRouter、Moonshot、智谱、阿里百炼……凡是"OpenAI 兼容"接口的都能用，填对方文档给的 Base URL 和模型名即可。Anthropic 接口要在余见里把类型切到「Anthropic」。\n本机跑 Ollama / LM Studio 的，Base URL 填 http://电脑IP:11434/v1，Key 留空，再开「仅本地模型」，数据不出局域网。'),
          h('想要短剧那种配音'),
          p('那是另一类服务（豆包语音 / MiniMax），不走这里的模型端点。更多 → 「怎么开通真人感配音」有单独的教程。'),
          h('花了多少'),
          p('更多 → 用量与花费，能看到余见一共用了多少 token、按厂商标价估算的金额。'),
        ],
      ),
    );
  }
}
