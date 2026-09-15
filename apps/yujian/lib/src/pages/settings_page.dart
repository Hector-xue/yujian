import 'package:flutter/material.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';

import '../app_state.dart';
import '../settings_store.dart';

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
  late String personaId;
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
    personaId = s.personaId;
  }

  Settings _draft() => Settings(baseUrl: baseUrl.text.trim(), apiKey: apiKey.text.trim(), model: model.text.trim(), personaId: personaId);

  Future<void> _probe() async {
    final cfg = _draft().providerConfig;
    if (cfg == null) {
      setState(() => probeResult = '先填 Base URL 和模型名');
      return;
    }
    setState(() {
      probing = true;
      probeResult = null;
    });
    final c = await CapabilityProbe.run(OpenAICompatProvider(cfg));
    if (!mounted) return;
    setState(() {
      probing = false;
      probeResult = c.error != null
          ? '连不上：${c.error}'
          : '对话 ${c.chat ? '✓' : '✗'} · JSON 输出 ${c.jsonOutput ? '✓' : '✗（解析会退回规则）'} · ${c.latency?.inMilliseconds ?? '-'} ms';
    });
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
          TextField(controller: baseUrl, decoration: const InputDecoration(labelText: 'Base URL', hintText: 'https://api.deepseek.com/v1'), keyboardType: TextInputType.url),
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
          Row(
            children: [
              OutlinedButton(onPressed: probing ? null : _probe, child: Text(probing ? '测试中…' : '测试连接')),
              const SizedBox(width: 12),
              if (probeResult != null) Expanded(child: Text(probeResult!, style: theme.textTheme.bodySmall)),
            ],
          ),
          const SizedBox(height: 28),
          Text('人格', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('只改语气。金额、时间、余额、确认流程它碰不到。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final p in builtinPersonas)
            RadioListTile<String>(
              value: p.id,
              groupValue: personaId,
              onChanged: (v) => setState(() => personaId = v!),
              contentPadding: EdgeInsets.zero,
              title: Text(p.name),
              subtitle: Text('${p.tagline} · "${p.templates['recorded']?.replaceAll('{n}', '1')}"', style: theme.textTheme.bodySmall),
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
