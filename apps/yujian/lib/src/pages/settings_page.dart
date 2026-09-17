import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../widgets/persona_avatar.dart';

/// 模型与人格（§9 配置中心是一等功能）。能力按实测：点"测试连接"真发请求。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController baseUrl;
  late final TextEditingController apiKey;
  late final TextEditingController model;
  late final TextEditingController visionModel;
  late String personaId;
  late String providerType;
  late bool localOnly;
  late bool redact;
  String? probeResult;
  var probing = false;
  var showKey = false;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context).settings;
    baseUrl = TextEditingController(text: s.baseUrl ?? '');
    apiKey = TextEditingController(text: s.apiKey ?? '');
    model = TextEditingController(text: s.model ?? '');
    visionModel = TextEditingController(text: s.visionModel ?? '');
    personaId = s.personaId;
    providerType = s.providerType;
    localOnly = s.localOnly;
    redact = s.redact;
  }

  Settings _draft() => AppScope.of(context).settings.copyWith(baseUrl: baseUrl.text.trim(), apiKey: apiKey.text.trim(), model: model.text.trim(), personaId: personaId, visionModel: visionModel.text.trim(), providerType: providerType, localOnly: localOnly, redact: redact);

  Future<void> _probe() async {
    final cfg = _draft().providerConfig;
    if (cfg == null) {
      setState(() => probeResult = localOnly && baseUrl.text.trim().isNotEmpty && !isLocalEndpoint(baseUrl.text.trim()) ? '开了"仅本地模型"，这个地址不在本机/内网，不会调用' : '先填 Base URL 和模型名');
      return;
    }
    setState(() {
      probing = true;
      probeResult = null;
    });
    final ChatProvider p = cfg.type == ProviderType.anthropic ? AnthropicProvider(cfg) : OpenAICompatProvider(cfg);
    final c = await CapabilityProbe.run(p, testVision: true);
    if (!mounted) return;
    setState(() {
      probing = false;
      probeResult = c.error != null
          ? '连不上：${c.error}'
          : '对话 ${c.chat ? '✓' : '✗'} · JSON ${c.jsonOutput ? '✓' : '✗（解析会退回规则）'} · 看图 ${c.vision == true ? '✓' : '✗'} · ${c.latency?.inMilliseconds ?? '-'} ms';
    });
  }

  Future<void> _importPersona(BuildContext context) async {
    final app = AppScope.of(context);
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('人格包 JSON'),
        content: TextField(controller: ctl, maxLines: 8, decoration: const InputDecoration(hintText: '{"id":"my","name":"…","tagline":"…","style":"风格描述","templates":{"greeting":"…","recorded":"已记 {n} 笔"}}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final j = (jsonDecode(ctl.text) as Map).cast<String, Object?>();
      final pack = PersonaPack.fromJson(j);
      if (pack.id.isEmpty || builtinPersonas.any((b) => b.id == pack.id)) throw const FormatException('id 不能为空或与内置重名');
      final missing = PersonaEvent.values.where((e) => !pack.templates.containsKey(e.name)).map((e) => e.name).toList();
      if (missing.isNotEmpty) throw FormatException('templates 缺 ${missing.join('、')}');
      await app.saveSettings(app.settings.copyWith(customPersona: j, personaId: pack.id));
      if (mounted) setState(() => personaId = pack.id);
    } catch (e) {
      final msg = e is FormatException ? e.message : '$e';
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('人格包不合法：$msg')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('模型与人格')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('模型', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('OpenAI 兼容接口：OpenAI、DeepSeek、OpenRouter、Ollama（http://主机:11434/v1）、LM Studio 都行。不填就只用规则解析，一样能记账。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'openai', label: Text('OpenAI 兼容')), ButtonSegment(value: 'anthropic', label: Text('Anthropic'))],
            selected: {providerType},
            onSelectionChanged: (v) => setState(() => providerType = v.first),
          ),
          const SizedBox(height: 12),
          TextField(controller: baseUrl, decoration: InputDecoration(labelText: 'Base URL', hintText: providerType == 'anthropic' ? 'https://api.anthropic.com/v1' : 'https://api.deepseek.com/v1'), keyboardType: TextInputType.url),
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
          TextField(controller: model, decoration: const InputDecoration(labelText: '模型名', hintText: 'deepseek-chat')),
          const SizedBox(height: 12),
          TextField(controller: visionModel, decoration: const InputDecoration(labelText: '看图模型名（可选）', hintText: '识别截图/小票用；留空则用上面的模型', helperText: '如 qwen3-vl、gpt-4o-mini；文本模型不支持看图时填这个')),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(onPressed: probing ? null : _probe, child: Text(probing ? '测试中…' : '测试连接')),
              const SizedBox(width: 12),
              if (probeResult != null) Expanded(child: Text(probeResult!, style: theme.textTheme.bodySmall)),
            ],
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('仅本地模型'),
            subtitle: Text('端点不在本机/内网（localhost、192.168.x、10.x、.local）时一律不调用，只用规则解析', style: theme.textTheme.bodySmall),
            value: localOnly,
            onChanged: (v) => setState(() => localOnly = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('发送前脱敏'),
            subtitle: Text('卡号、手机号、身份证、订单号、邮箱替换成占位符再发给模型；金额不动', style: theme.textTheme.bodySmall),
            value: redact,
            onChanged: (v) => setState(() => redact = v),
          ),
          const SizedBox(height: 20),
          Text('人格', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('只改语气。金额、时间、余额、确认流程它碰不到。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: personaId,
            onChanged: (v) => setState(() => personaId = v ?? personaId),
            child: Column(
              children: [
                for (final p in [...builtinPersonas, if (app.settings.customPersona != null) PersonaPack.fromJson(app.settings.customPersona!)])
                  RadioListTile<String>(
                    value: p.id,
                    contentPadding: EdgeInsets.zero,
                    secondary: PersonaAvatar(p, size: 36),
                    title: Text(p.name),
                    subtitle: Text('${p.tagline} · "${p.templates['recorded']?.replaceAll('{n}', '1') ?? ''}"', style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => _importPersona(context),
            icon: const Icon(Icons.add, size: 18),
            label: Text(app.settings.customPersona == null ? '导入自定义人格包（JSON）' : '替换自定义人格包'),
          ),
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
      ),
    );
  }
}
