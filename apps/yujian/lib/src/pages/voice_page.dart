import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import '../settings_store.dart';
import '../voice/local_asr_native.dart' if (dart.library.js_interop) '../voice/local_asr_web.dart';
import '../voice/local_tts_native.dart' if (dart.library.js_interop) '../voice/local_tts_web.dart';
import '../voice/offline_asr_sheet.dart';
import '../voice/speech_output.dart';
import '../voice/vendor_voices.dart';
import '../widgets/disclosure_tile.dart';
import '../widgets/model_picker.dart';
import '../widgets/picker_field.dart';
import 'tts_guide_page.dart';

/// 语音：听（离线识别包 / 云端转写）和说（单选：系统朗读 / 主模型自带语音 / 豆包 / MiniMax / OpenAI 兼合成）。
/// 「说」是明确的单选，选哪个用哪个；填空只在选了云端时才露出来。
/// [embedded] 为真时只出正文（给「模型与语音」的标签页用），不带自己的 Scaffold / 顶栏。
class VoicePage extends StatefulWidget {
  final bool embedded;
  const VoicePage({super.key, this.embedded = false});
  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  late final TextEditingController transcribeModel;
  late final TextEditingController speechModel;
  late final TextEditingController speechVoice;
  late final TextEditingController speechStyle;
  late final TextEditingController doubaoKey;
  late final TextEditingController doubaoAppId;
  late final TextEditingController doubaoAccess;
  late final TextEditingController minimaxKey;
  late final TextEditingController minimaxGroup;
  late final TextEditingController minimaxModel;
  var showKeys = false;
  final _preview = SpeechOutput();
  String? result;
  var testing = false;
  var listing = false;
  bool? asrInstalled;
  bool? ttsInstalled;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context).settings;
    transcribeModel = TextEditingController(text: s.transcribeModel ?? '');
    speechModel = TextEditingController(text: s.speechModel ?? '');
    speechVoice = TextEditingController(text: s.speechVoice ?? '');
    speechStyle = TextEditingController(text: s.speechStyle ?? '');
    doubaoKey = TextEditingController(text: s.doubaoApiKey ?? '');
    doubaoAppId = TextEditingController(text: s.doubaoAppId ?? '');
    doubaoAccess = TextEditingController(text: s.doubaoAccessKey ?? '');
    minimaxKey = TextEditingController(text: s.minimaxApiKey ?? '');
    minimaxGroup = TextEditingController(text: s.minimaxGroupId ?? '');
    minimaxModel = TextEditingController(text: s.minimaxModel);
    _probe();
  }

  Future<void> _probe() async {
    final a = await LocalAsr.installed();
    final t = await LocalTts.installed();
    if (mounted) {
      setState(() {
        asrInstalled = a;
        ttsInstalled = t;
      });
    }
  }

  @override
  void dispose() {
    _preview.dispose();
    for (final c in [transcribeModel, speechModel, speechVoice, speechStyle, doubaoKey, doubaoAppId, doubaoAccess, minimaxKey, minimaxGroup, minimaxModel]) {
      c.dispose();
    }
    super.dispose();
  }

  Settings _draft() => AppScope.of(context).settings.copyWith(
      transcribeModel: transcribeModel.text.trim(),
      speechModel: speechModel.text.trim(),
      speechVoice: speechVoice.text.trim(),
      speechStyle: speechStyle.text.trim(),
      doubaoApiKey: doubaoKey.text.trim(),
      doubaoAppId: doubaoAppId.text.trim(),
      doubaoAccessKey: doubaoAccess.text.trim(),
      minimaxApiKey: minimaxKey.text.trim(),
      minimaxGroupId: minimaxGroup.text.trim(),
      minimaxModel: minimaxModel.text.trim().isEmpty ? 'speech-02-hd' : minimaxModel.text.trim());

  Future<void> _pick(TextEditingController target) async {
    final s = AppScope.of(context).settings;
    setState(() => listing = true);
    final picked = await pickModelFromEndpoint(context, baseUrl: s.baseUrl ?? '', apiKey: s.apiKey ?? '', providerType: s.providerType, current: target.text);
    if (!mounted) return;
    setState(() {
      listing = false;
      if (picked != null) target.text = picked;
    });
  }

  /// 单选：选云端但没端点 → 提示。选中即保存。
  Future<void> _chooseEngine(String engine) async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if ((engine == 'cloud' || engine == 'omni') && app.settings.providerConfig == null) {
      messenger.showSnackBar(const SnackBar(content: Text('云端合成用「主模型」里的端点，先去那里配好')));
      return;
    }
    await app.saveSettings(app.settings.copyWith(speechEngine: engine));
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    final d = _draft();
    setState(() {
      testing = true;
      result = null;
    });
    const line = '主人好呀，今天想记点什么？';
    String r;
    switch (d.speechEngine) {
      case 'omni' when d.providerConfig == null:
        r = '先到「主模型」配好端点';
      case 'cloud' when !SpeechOutput.cloudConfigured(d):
        r = d.providerConfig == null ? '先到「主模型」配好端点' : '先填云端语音合成模型';
      case 'doubao' when !d.doubaoTts.configured:
        r = '先粘贴豆包的 API Key';
      case 'minimax' when !d.minimaxTts.configured:
        r = '先粘贴 MiniMax 的 API Key';
      case 'system':
        await _preview.speakWith('system', line, d);
        r = '已交给系统朗读（没声音 = 手机没装语音引擎）';
      default:
        r = await _preview.speakWith(d.speechEngine, line, d, log: AppScope.of(context).netLog) ? '合成成功，已播放' : '合成失败：${_preview.lastError}';
    }
    if (!mounted) return;
    setState(() {
      testing = false;
      result = r;
    });
  }

  Widget _keyField(TextEditingController c, String label, {String? helper}) => TextField(
        controller: c,
        obscureText: !showKeys,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          suffixIcon: IconButton(tooltip: showKeys ? '隐藏 Key' : '显示 Key', icon: Icon(showKeys ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => showKeys = !showKeys)),
        ),
      );

  Widget _voicePicker(String label, List<({String id, String name})> voices, String current, void Function(String) onPick) => PickerField<String>(
        value: voices.any((v) => v.id == current) ? current : voices.first.id,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [for (final v in voices) DropdownMenuItem(value: v.id, child: Text(v.name))],
        onChanged: (v) {
          if (v != null) onPick(v);
        },
      );

  Widget _guideLink(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TtsGuidePage())),
          icon: const Icon(Icons.help_outline, size: 18),
          label: const Text('还没开通？看教程'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final s = app.settings;
    final hasEndpoint = s.providerConfig != null;
    final engine = s.speechEngine;
    final muted = theme.textTheme.bodySmall;

    Widget engineTile(String value, String title, String subtitle, {Widget? trailing, List<Widget> body = const []}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          RadioListTile<String>(
            value: value,
            contentPadding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
            title: Text(title),
            subtitle: Text(subtitle, style: muted),
            secondary: trailing,
          ),
          if (engine == value && body.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body)),
        ]);

    final body = ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (s.offlineMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('纯本地模式已开：云端转写和云端朗读都不会用（只用离线语音包 / 手机系统识别 / 系统朗读），配置保留。到「更多 → 隐私」可关掉。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ),
          Text('听你说', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('按顺序试：${asrInstalled == true ? '离线识别包 → ' : ''}手机系统识别${(s.transcribeModel ?? '').isNotEmpty ? ' → 云端转写' : ''}。国产 ROM 常常没有系统识别，装离线包最省心。', style: muted),
          const SizedBox(height: 8),
          // 听你说 / 它说话 各一张卡
          GlassCard(child: Column(children: [
          if (LocalAsr.supported)
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              leading: Icon(asrInstalled == true ? Icons.offline_pin : Icons.download_for_offline_outlined, color: theme.colorScheme.primary),
              title: const Text('离线识别包'),
              subtitle: Text(asrInstalled == true ? '已安装，说话在本机识别、不联网' : '约 ${LocalAsr.approxMb} MB，下载一次', style: muted),
              trailing: asrInstalled == true
                  ? TextButton(
                      onPressed: () async {
                        await LocalAsr.uninstall();
                        await _probe();
                      },
                      child: const Text('删除'))
                  : FilledButton.tonal(
                      onPressed: () async {
                        await showOfflineAsrDownload(context);
                        await _probe();
                      },
                      child: const Text('下载')),
            ),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            title: Text('云端转写（可选，一般不用）', style: theme.textTheme.bodyMedium),
            subtitle: Text(hasEndpoint ? '离线包和系统识别都不行时的兜底' : '先到「主模型」配好端点', style: muted),
            children: [
              TextField(
                controller: transcribeModel,
                enabled: hasEndpoint,
                decoration: InputDecoration(
                  labelText: '转写模型名',
                  hintText: '如 whisper-1、FunAudioLLM/SenseVoiceSmall',
                  helperText: '余见自己录音，发到端点的 /audio/transcriptions 转成文字',
                  suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listing || !hasEndpoint ? null : () => _pick(transcribeModel), icon: const Icon(Icons.list_alt_outlined)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
          ])),
          const SizedBox(height: 24),
          Text('它说话', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('选一个。对话页开了「朗读」就用它读回复。', style: muted),
          const SizedBox(height: 8),
          GlassCard(child: Column(children: [
          RadioGroup<String>(
            groupValue: engine,
            onChanged: (v) => v == null ? null : _chooseEngine(v),
            child: Column(children: [
              engineTile('system', '手机系统朗读', '免费、不用装东西；机械感重'),
              engineTile(
                'omni',
                '主模型自带语音',
                hasEndpoint ? '主模型是多模态 Omni 模型（如 Qwen-Omni）时不用再配别的，同一把 key 直接开口' : '先到「主模型」配好端点；主模型要是 Omni 多模态模型',
                body: [
                  _voicePicker('音色', const [(id: 'Cherry', name: 'Cherry · 女'), (id: 'Serena', name: 'Serena · 女'), (id: 'Chelsie', name: 'Chelsie · 女'), (id: 'Ethan', name: 'Ethan · 男')], s.omniVoice,
                      (v) => app.saveSettings(app.settings.copyWith(omniVoice: v))),
                  const SizedBox(height: 6),
                  Text('主模型不是 Omni 的话试听会报「没有返回音频」，那就选下面的豆包 / MiniMax。', style: muted),
                ],
              ),
              engineTile(
                'doubao',
                '豆包语音（推荐）',
                s.doubaoTts.configured ? '已配好。抖音短剧同款，有情绪；按字数计费' : '抖音短剧同款，有情绪，中文最自然；要一个火山引擎的 API Key',
                body: [
                  _keyField(doubaoKey, 'API Key', helper: '火山引擎 → 豆包语音 → 应用里复制；只存本机安全存储'),
                  const SizedBox(height: 16),
                  _voicePicker('音色', doubaoVoices, s.doubaoVoice, (v) => app.saveSettings(app.settings.copyWith(doubaoVoice: v))),
                  DisclosureTile(
                    title: Text('高级：老账号用 App ID + Access Token', style: theme.textTheme.bodySmall),
                    children: [
                      TextField(controller: doubaoAppId, decoration: const InputDecoration(labelText: 'App ID')),
                      const SizedBox(height: 8),
                      _keyField(doubaoAccess, 'Access Token'),
                      const SizedBox(height: 8),
                    ],
                  ),
                  _guideLink(context),
                ],
              ),
              engineTile(
                'minimax',
                'MiniMax 语音',
                s.minimaxTts.configured ? '已配好。speech-02-hd，有情绪；按字数计费' : '有情绪、很自然；要一个 MiniMax 的 API Key',
                body: [
                  _keyField(minimaxKey, 'API Key', helper: 'MiniMax 开放平台 → 接口密钥；只存本机安全存储'),
                  const SizedBox(height: 16),
                  _voicePicker('音色', minimaxVoices, s.minimaxVoice, (v) => app.saveSettings(app.settings.copyWith(minimaxVoice: v))),
                  DisclosureTile(
                    title: Text('高级', style: theme.textTheme.bodySmall),
                    children: [
                      TextField(controller: minimaxGroup, decoration: const InputDecoration(labelText: 'GroupId（老账号才要）')),
                      const SizedBox(height: 8),
                      TextField(controller: minimaxModel, decoration: const InputDecoration(labelText: '模型', hintText: '如 speech-02-hd')),
                      const SizedBox(height: 8),
                    ],
                  ),
                  _guideLink(context),
                ],
              ),
              engineTile(
                'cloud',
                'OpenAI 兼容语音合成',
                hasEndpoint ? '用「主模型」的端点（硅基流动 CosyVoice、OpenAI tts）' : '先到「主模型」配好端点',
                body: [
                  TextField(
                    controller: speechModel,
                    decoration: InputDecoration(
                      labelText: '合成模型名',
                      hintText: '如 gpt-4o-mini-tts、tts-1、FunAudioLLM/CosyVoice2-0.5B',
                      suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listing ? null : () => _pick(speechModel), icon: const Icon(Icons.list_alt_outlined)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: speechVoice, decoration: const InputDecoration(labelText: '音色', hintText: '如 alloy、nova、FunAudioLLM/CosyVoice2-0.5B:anna', helperText: '各家音色名不同，看服务商文档；留空用 alloy', helperMaxLines: 2)),
                ],
              ),
            ]),
          ),
          if (ttsInstalled == true)
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              leading: Icon(Icons.delete_sweep_outlined, color: theme.colorScheme.primary),
              title: const Text('旧版下载的离线语音包'),
              subtitle: Text('0.8.7 起不再用它（效果差）。占约 ${LocalTts.approxMb} MB，删掉腾地方', style: muted),
              trailing: TextButton(
                  onPressed: () async {
                    await LocalTts.uninstall();
                    await _probe();
                  },
                  child: const Text('删除')),
            ),
          ])),
          if (engine == 'doubao' || engine == 'minimax' || engine == 'cloud' || engine == 'omni') ...[
            const SizedBox(height: 4),
            TextField(
              controller: speechStyle,
              decoration: InputDecoration(
                labelText: '语气（可选）',
                hintText: '用撒娇甜蜜的语气 / 沉稳一点',
                helperText: engine == 'minimax' ? 'MiniMax 只认开心 / 伤心 / 生气 / 平静这几种，会挑最接近的' : engine == 'cloud' ? '只有 gpt-4o-mini-tts 这类认，其他会忽略' : '写一句话，它会照着念',
                helperMaxLines: 2,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(onPressed: testing ? null : _test, icon: const Icon(Icons.volume_up_outlined, size: 18), label: Text(testing ? '合成中…' : '试听当前选的')),
            const SizedBox(width: 12),
            if (result != null) Expanded(child: Text(result!, style: muted)),
          ]),
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
    return Scaffold(appBar: AppBar(title: const Text('语音')), body: body);
  }
}
