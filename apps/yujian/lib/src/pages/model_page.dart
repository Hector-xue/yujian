import 'package:flutter/material.dart';
import 'package:providers/providers.dart';

import '../app_state.dart';
import '../privacy/net_log.dart';
import '../settings_store.dart';
import '../theme.dart';
import '../widgets/disclosure_tile.dart';
import '../widgets/model_picker.dart';
import 'api_guide_page.dart';
import 'usage_page.dart';

/// 模型与 API（§9 配置中心是一等功能）。只管"用哪个模型、怎么连"：接口类型、地址、Key、模型名、看图模型、隐私开关。
/// 语音在同一入口的另一个标签页（[AiPage]），人格 / 外观各有自己的页。能力按实测：点"测试连接"真发请求。
/// [embedded] 为真时只出正文，不带 Scaffold / 顶栏。
class ModelPage extends StatefulWidget {
  /// 从教程带过来的一套配置，只预填不保存。
  final ApiPreset? preset;
  final bool embedded;
  const ModelPage({super.key, this.preset, this.embedded = false});
  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  late final TextEditingController baseUrl;
  late final TextEditingController apiKey;
  late final TextEditingController model;
  late final TextEditingController visionModel;
  late String providerType;
  late bool localOnly;
  late bool redact;
  String? probeResult;
  var probing = false;
  var showKey = false;
  var listingModels = false;
  var showOptional = false;
  ApiPreset? _preset; // 教程带来的整套配置（含语音部分），保存时一起落

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context).settings;
    final p = widget.preset;
    baseUrl = TextEditingController(text: p?.baseUrl ?? s.baseUrl ?? '');
    apiKey = TextEditingController(text: s.apiKey ?? '');
    model = TextEditingController(text: p?.model ?? s.model ?? '');
    visionModel = TextEditingController(text: p?.visionModel ?? s.visionModel ?? '');
    providerType = p?.providerType ?? s.providerType;
    localOnly = s.localOnly;
    redact = s.redact;
    _preset = p;
    showOptional = (s.visionModel ?? '').isNotEmpty;
  }

  @override
  void dispose() {
    for (final c in [baseUrl, apiKey, model, visionModel]) {
      c.dispose();
    }
    super.dispose();
  }

  Settings _draft() {
    final p = _preset;
    return AppScope.of(context).settings.copyWith(
      baseUrl: baseUrl.text.trim(),
      apiKey: apiKey.text.trim(),
      model: model.text.trim(),
      visionModel: visionModel.text.trim(),
      providerType: providerType,
      localOnly: localOnly,
      redact: redact,
      // 教程一键填入的语音部分：只在有值时覆盖，用户自己配过的不动
      transcribeModel: p?.transcribeModel,
      speechModel: p?.speechModel,
      speechVoice: p?.speechVoice,
      speechEngine: p?.speechEngine,
    );
  }

  static bool _looksLikeBadModel(String err) =>
      RegExp(r'model|模型', caseSensitive: false).hasMatch(err) && RegExp(r'not (found|exist|support)|invalid|unknown|supported|does not exist|不存在|不支持', caseSensitive: false).hasMatch(err);

  Future<void> _probe() async {
    final app = AppScope.of(context);
    final cfg = _draft().providerConfig;
    if (cfg == null) {
      setState(() => probeResult = app.settings.offlineMode
          ? '纯本地模式已开，不联网测试（更多 → 隐私 可关掉）'
          : localOnly && baseUrl.text.trim().isNotEmpty && !isLocalEndpoint(baseUrl.text.trim())
              ? '开了"仅本地模型"，这个地址不在本机/内网，不会调用'
              : '先填 Base URL 和模型名');
      return;
    }
    setState(() {
      probing = true;
      probeResult = null;
    });
    final ChatProvider raw = cfg.type == ProviderType.anthropic ? AnthropicProvider(cfg) : OpenAICompatProvider(cfg);
    // 测试连接也是真调用，照进出网记录（标 probe）
    final host = hostOf(cfg.baseUrl);
    final p = MeteredProvider(raw, purpose: 'probe', onCall: (c) => app.netLog.recordCall(c, host: host, redacted: false));
    final c = await CapabilityProbe.run(p, testVision: true);
    if (!mounted) return;
    setState(() {
      probing = false;
      probeResult = c.error != null
          ? '连不上：${c.error}${_looksLikeBadModel(c.error!) ? '\n→ 点模型名右侧的列表图标选一个端点认的名字' : ''}'
          : '对话 ${c.chat ? '✓' : '✗'} · JSON ${c.jsonOutput ? '✓' : '✗（解析会退回规则）'} · 看图 ${c.vision == true ? '✓' : '✗'} · ${c.latency?.inMilliseconds ?? '-'} ms';
    });
  }

  Future<void> _pickModel(TextEditingController target) async {
    setState(() => listingModels = true);
    final picked = await pickModelFromEndpoint(context, baseUrl: baseUrl.text, apiKey: apiKey.text, providerType: providerType, current: target.text);
    if (!mounted) return;
    setState(() {
      listingModels = false;
      if (picked != null) target.text = picked;
    });
  }

  Future<void> _openGuide() async {
    final p = await Navigator.of(context).push<ApiPreset>(MaterialPageRoute(builder: (_) => const ApiGuidePage(asPicker: true)));
    if (p == null || !mounted) return;
    setState(() {
      _preset = p;
      providerType = p.providerType;
      baseUrl.text = p.baseUrl;
      model.text = p.model;
      visionModel.text = p.visionModel ?? '';
      showOptional = p.visionModel != null;
      probeResult = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final body = ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (app.settings.offlineMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('纯本地模式已开：这里的配置会保存，但不会调用任何模型，直到你在「更多 → 隐私」关掉它。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ),
          GlassCard(
            child: ListTile(
              leading: Icon(Icons.help_outline, color: theme.colorScheme.primary),
              title: const Text('还没有 API Key？'),
              subtitle: Text('去哪注册、怎么充值、填哪三项——拿 DeepSeek 和硅基流动举例，看完能一键填入', style: theme.textTheme.bodySmall),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openGuide,
            ),
          ),
          const SizedBox(height: 16),
          Text('主模型（一个就够）', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('读字、看图、陪聊都用它。OpenAI 兼容接口都行：DeepSeek、硅基流动、阿里云百炼、OpenAI、OpenRouter、Ollama（http://主机:11434/v1）。不填就只用规则解析，一样能记账。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          GlassCard(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'openai', label: Text('OpenAI 兼容')), ButtonSegment(value: 'anthropic', label: Text('Anthropic'))],
            selected: {providerType},
            onSelectionChanged: (v) => setState(() => providerType = v.first),
          ),
          const SizedBox(height: 12),
          TextField(
              controller: baseUrl,
              decoration: InputDecoration(labelText: 'Base URL', hintText: providerType == 'anthropic' ? 'https://api.anthropic.com/v1' : 'https://api.deepseek.com/v1'),
              keyboardType: TextInputType.url),
          const SizedBox(height: 12),
          TextField(
            controller: apiKey,
            obscureText: !showKey,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: '只存在本机安全存储里',
              suffixIcon: IconButton(icon: Icon(showKey ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => showKey = !showKey)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: model,
            decoration: InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-flash',
              helperText: '点右侧列表从端点拉可用模型，别手猜名字',
              suffixIcon: IconButton(
                  tooltip: '从端点拉模型列表',
                  onPressed: listingModels ? null : () => _pickModel(model),
                  icon: listingModels ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.list_alt_outlined)),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(onPressed: probing ? null : _probe, child: Text(probing ? '测试中…' : '测试连接')),
              const SizedBox(width: 12),
              if (probeResult != null) Expanded(child: Text(probeResult!, style: theme.textTheme.bodySmall)),
            ],
          ),
          const SizedBox(height: 8),
          DisclosureTile(
            initiallyExpanded: showOptional,
            title: Text('可选：看图用另一个模型', style: theme.textTheme.bodyMedium),
            subtitle: Text('主模型「测试连接」看图显示 ✗ 时才需要', style: theme.textTheme.bodySmall),
            children: [
              TextField(
                controller: visionModel,
                decoration: InputDecoration(
                  labelText: '看图模型名',
                  hintText: '如 Qwen/Qwen3-VL-8B-Instruct、gpt-4o-mini',
                  helperText: '识别截图 / 小票用；留空 = 用主模型',
                  suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listingModels ? null : () => _pickModel(visionModel), icon: const Icon(Icons.list_alt_outlined)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
          Text('语音识别 / 朗读在旁边的「语音」页里配，可选。', style: theme.textTheme.bodySmall),
          ]))),
          const SizedBox(height: 12),
          GlassCard(child: Column(children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            title: const Text('仅本地模型'),
            subtitle: Text('端点不在本机/内网（localhost、192.168.x、10.x、.local）时一律不调用，只用规则解析', style: theme.textTheme.bodySmall),
            value: localOnly,
            onChanged: (v) => setState(() => localOnly = v),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            title: const Text('发送前脱敏'),
            subtitle: Text('卡号、手机号、身份证、订单号、邮箱替换成占位符再发给模型；金额不动', style: theme.textTheme.bodySmall),
            value: redact,
            onChanged: (v) => setState(() => redact = v),
          ),
          const Divider(indent: 16),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: Icon(Icons.data_usage_outlined, color: theme.colorScheme.primary),
            title: const Text('用量与花费'),
            subtitle: Text(_usageLine(app), style: theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UsagePage())),
          ),
          ])),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              await app.saveSettings(_draft());
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
              Navigator.of(context).pop();
            },
            child: const Text('保存'),
          ),
        ],
      );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('模型与 API')), body: body);
  }

  static String _usageLine(AppState app) {
    final n = DateTime.now();
    final m = app.usage.summary(from: DateTime(n.year, n.month, 1));
    if (m.tokens == 0 && m.chars == 0) return '本月还没用过模型';
    return '本月 ${fmtTokens(m.tokens)} token${m.unknownModels.isEmpty ? '，约 ¥${m.knownCost.toStringAsFixed(2)}' : '，已知单价部分约 ¥${m.knownCost.toStringAsFixed(2)}'}';
  }
}
