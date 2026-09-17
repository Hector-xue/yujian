import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../theme.dart';
import '../voice/local_asr_native.dart' if (dart.library.js_interop) '../voice/local_asr_web.dart';
import '../voice/offline_asr_sheet.dart';
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
  late final TextEditingController transcribeModel;
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
    transcribeModel = TextEditingController(text: s.transcribeModel ?? '');
    personaId = s.personaId;
    providerType = s.providerType;
    localOnly = s.localOnly;
    redact = s.redact;
  }

  Settings _draft() => AppScope.of(context).settings.copyWith(
      baseUrl: baseUrl.text.trim(),
      apiKey: apiKey.text.trim(),
      model: model.text.trim(),
      personaId: personaId,
      visionModel: visionModel.text.trim(),
      transcribeModel: transcribeModel.text.trim(),
      providerType: providerType,
      localOnly: localOnly,
      redact: redact);

  static bool _looksLikeBadModel(String err) =>
      RegExp(r'model|模型', caseSensitive: false).hasMatch(err) && RegExp(r'not (found|exist|support)|invalid|unknown|supported|does not exist|不存在|不支持', caseSensitive: false).hasMatch(err);

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
          ? '连不上：${c.error}${_looksLikeBadModel(c.error!) ? '\n→ 点模型名右侧的列表图标选一个端点认的名字' : ''}'
          : '对话 ${c.chat ? '✓' : '✗'} · JSON ${c.jsonOutput ? '✓' : '✗（解析会退回规则）'} · 看图 ${c.vision == true ? '✓' : '✗'} · ${c.latency?.inMilliseconds ?? '-'} ms';
    });
  }

  var listingModels = false;

  /// 从端点拉模型列表让用户点选，省得手打错模型名（DeepSeek 这类名字和产品名对不上）。
  Future<void> _pickModel(TextEditingController target) async {
    final base = baseUrl.text.trim();
    if (base.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先填 Base URL')));
      return;
    }
    setState(() => listingModels = true);
    List<String> ids;
    try {
      ids =
          await listModels(ProviderConfig(name: 'user', type: providerType == 'anthropic' ? ProviderType.anthropic : ProviderType.openaiCompat, baseUrl: base, apiKey: apiKey.text.trim(), model: '-'));
    } on ProviderException catch (e) {
      if (mounted) {
        setState(() => listingModels = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拿不到模型列表：${e.message}。手填模型名也行')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => listingModels = false);
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('端点返回了空列表，手填模型名')));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ModelPicker(ids: ids, current: target.text.trim()),
    );
    if (picked != null && mounted) setState(() => target.text = picked);
  }

  Future<void> _importPersona(BuildContext context) async {
    final app = AppScope.of(context);
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('人格包 JSON'),
        content: TextField(
            controller: ctl, maxLines: 8, decoration: const InputDecoration(hintText: '{"id":"my","name":"…","tagline":"…","style":"风格描述","templates":{"greeting":"…","recorded":"已记 {n} 笔"}}')),
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
              hintText: 'deepseek-chat',
              helperText: '点右侧列表从端点拉可用模型，别手猜名字',
              suffixIcon: IconButton(
                  tooltip: '从端点拉模型列表',
                  onPressed: listingModels ? null : () => _pickModel(model),
                  icon: listingModels ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.list_alt_outlined)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: visionModel,
            decoration: InputDecoration(
              labelText: '看图模型名（可选）',
              hintText: '识别截图/小票用；留空则用上面的模型',
              helperText: '如 qwen3-vl、gpt-4o-mini；文本模型不支持看图时填这个',
              suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listingModels ? null : () => _pickModel(visionModel), icon: const Icon(Icons.list_alt_outlined)),
            ),
          ),
          const SizedBox(height: 12),
          if (LocalAsr.supported) ...[
            FutureBuilder<bool>(
              future: LocalAsr.installed(),
              builder: (ctx, snap) {
                final on = snap.data == true;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(on ? Icons.offline_pin : Icons.download_for_offline_outlined, color: theme.colorScheme.primary),
                  title: const Text('离线语音包'),
                  subtitle: Text(on ? '已安装。说话在本机识别，不联网、不看手机系统' : '约 ${LocalAsr.approxMb} MB，下载一次；手机系统语音不可用时的正解', style: theme.textTheme.bodySmall),
                  trailing: on
                      ? TextButton(
                          onPressed: () async {
                            await LocalAsr.uninstall();
                            if (mounted) setState(() {});
                          },
                          child: const Text('删除'))
                      : FilledButton.tonal(
                          onPressed: () async {
                            await showOfflineAsrDownload(context);
                            if (mounted) setState(() {});
                          },
                          child: const Text('下载')),
                );
              },
            ),
            const SizedBox(height: 4),
          ],
          TextField(
            controller: transcribeModel,
            decoration: InputDecoration(
              labelText: '语音转写模型（可选）',
              hintText: '如 whisper-1、FunAudioLLM/SenseVoiceSmall',
              helperText: '手机没有系统语音识别时的兜底：余见自己录音，发到同一端点的 /audio/transcriptions 转成文字',
              helperMaxLines: 3,
              suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listingModels ? null : () => _pickModel(transcribeModel), icon: const Icon(Icons.list_alt_outlined)),
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
          Text('外观', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('主题管质感和形状，强调色跟人格走。点了就生效。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: appThemes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (ctx, i) => _ThemeCard(
                  spec: appThemes[i],
                  accent: theme.colorScheme.primary,
                  selected: app.settings.themeId == appThemes[i].id,
                  onTap: () => app.saveSettings(app.settings.copyWith(themeId: appThemes[i].id))),
            ),
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

/// 模型列表底部弹层：可过滤，当前值高亮。
class _ModelPicker extends StatefulWidget {
  final List<String> ids;
  final String current;
  const _ModelPicker({required this.ids, required this.current});
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  var filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = widget.ids.where((id) => id.toLowerCase().contains(filter.toLowerCase())).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child:
                  TextField(autofocus: false, onChanged: (v) => setState(() => filter = v), decoration: InputDecoration(hintText: '过滤 ${widget.ids.length} 个模型', prefixIcon: const Icon(Icons.search))),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(child: Text('没有匹配的', style: theme.textTheme.bodySmall))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (ctx, i) {
                        final id = shown[i];
                        final selected = id == widget.current;
                        return ListTile(
                          dense: true,
                          title: Text(id, style: selected ? TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600) : null),
                          trailing: selected ? Icon(Icons.check, color: theme.colorScheme.primary, size: 18) : null,
                          onTap: () => Navigator.pop(ctx, id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主题预览卡：用该主题自己的 ThemeData 画一个小样，所见即所得。
class _ThemeCard extends StatelessWidget {
  final AppThemeSpec spec;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeCard({required this.spec, required this.accent, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = spec.build(accent);
    final y = t.extension<YujianColors>()!;
    final outer = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 132,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? outer.colorScheme.primary : outer.dividerTheme.color ?? Colors.black12, width: selected ? 2 : 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(child: spec.background?.call(context, accent) ?? ColoredBox(color: t.scaffoldBackgroundColor)),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(color: y.cardFill, borderRadius: BorderRadius.circular(y.radius / 2), border: Border.all(color: y.cardBorder, width: spec.id == 'cartoon' ? 1.5 : 0.6)),
                    alignment: Alignment.centerLeft,
                    child: Text('¥ 1,280', style: t.textTheme.titleMedium?.copyWith(color: y.balance, fontSize: 13)),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Container(width: 22, height: 8, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4))),
                    const SizedBox(width: 4),
                    Container(width: 14, height: 8, decoration: BoxDecoration(color: y.income, borderRadius: BorderRadius.circular(4))),
                  ]),
                  const Spacer(),
                  Text(spec.name, style: t.textTheme.titleMedium?.copyWith(fontSize: 13)),
                  Text(spec.tagline, style: t.textTheme.bodySmall?.copyWith(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (selected) Positioned(top: 6, right: 6, child: Icon(Icons.check_circle, size: 16, color: outer.colorScheme.primary)),
          ],
        ),
      ),
    );
  }
}
