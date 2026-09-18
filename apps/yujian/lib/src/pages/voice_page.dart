import 'package:flutter/material.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../voice/local_asr_native.dart' if (dart.library.js_interop) '../voice/local_asr_web.dart';
import '../voice/local_tts_native.dart' if (dart.library.js_interop) '../voice/local_tts_web.dart';
import '../voice/offline_asr_sheet.dart';
import '../voice/speech_output.dart';
import '../widgets/model_picker.dart';

/// 语音：听（离线识别包 / 云端转写）和说（三选一：系统朗读 / 离线语音包 / 云端合成）。
/// 「说」是明确的单选，选哪个用哪个；填空只在选了云端时才露出来。
class VoicePage extends StatefulWidget {
  const VoicePage({super.key});
  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  late final TextEditingController transcribeModel;
  late final TextEditingController speechModel;
  late final TextEditingController speechVoice;
  late final TextEditingController speechStyle;
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
    for (final c in [transcribeModel, speechModel, speechVoice, speechStyle]) {
      c.dispose();
    }
    super.dispose();
  }

  Settings _draft() => AppScope.of(context).settings.copyWith(
      transcribeModel: transcribeModel.text.trim(), speechModel: speechModel.text.trim(), speechVoice: speechVoice.text.trim(), speechStyle: speechStyle.text.trim());

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

  /// 单选：选离线但没装 → 先下载；选云端但没端点 → 提示。选中即保存。
  Future<void> _chooseEngine(String engine) async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (engine == 'offline' && ttsInstalled != true) {
      final ok = await showOfflineTtsDownload(context);
      _preview.refreshOffline();
      await _probe();
      if (!ok) return;
    }
    if (engine == 'cloud' && app.settings.providerConfig == null) {
      messenger.showSnackBar(const SnackBar(content: Text('云端合成用「模型与 API」里的端点，先去那里配好')));
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
      case 'cloud':
        if (!SpeechOutput.cloudConfigured(d)) {
          r = d.providerConfig == null ? '先到「模型与 API」配好端点' : '先填云端语音合成模型';
        } else {
          r = await _preview.speakCloud(line, d) ? '云端合成成功，已播放' : '云端合成失败：${_preview.lastError}';
        }
      case 'offline':
        r = await _preview.speakOffline(line, d) ? '离线合成成功，已播放' : '离线合成失败：${_preview.lastError}';
      default:
        await _preview.speakSystem(line);
        r = '已交给系统朗读（没声音 = 手机没装语音引擎）';
    }
    if (!mounted) return;
    setState(() {
      testing = false;
      result = r;
    });
  }

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
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            subtitle: Text(subtitle, style: muted),
            secondary: trailing,
          ),
          if (engine == value && body.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 0, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body)),
        ]);

    return Scaffold(
      appBar: AppBar(title: const Text('语音')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('听你说', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('按顺序试：${asrInstalled == true ? '离线识别包 → ' : ''}手机系统识别${(s.transcribeModel ?? '').isNotEmpty ? ' → 云端转写' : ''}。国产 ROM 常常没有系统识别，装离线包最省心。', style: muted),
          if (LocalAsr.supported)
            ListTile(
              contentPadding: EdgeInsets.zero,
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
            tilePadding: EdgeInsets.zero,
            title: Text('云端转写（可选，一般不用）', style: theme.textTheme.bodyMedium),
            subtitle: Text(hasEndpoint ? '离线包和系统识别都不行时的兜底' : '先到「模型与 API」配好端点', style: muted),
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
          const SizedBox(height: 24),
          Text('它说话', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('选一个。对话页开了「朗读」就用它读回复。', style: muted),
          RadioGroup<String>(
            groupValue: engine,
            onChanged: (v) => v == null ? null : _chooseEngine(v),
            child: Column(children: [
              engineTile('system', '手机系统朗读', '免费、不用装东西；机械感重'),
              engineTile(
                'offline',
                '离线真人感语音包',
                ttsInstalled == true ? '已安装。有语气有语调，在本机合成、不联网、不花钱' : '约 ${LocalTts.approxMb} MB 下载一次；有语气有语调，不联网、不花钱',
                trailing: ttsInstalled == true
                    ? TextButton(
                        onPressed: () async {
                          await LocalTts.uninstall();
                          _preview.refreshOffline();
                          if (engine == 'offline') await app.saveSettings(app.settings.copyWith(speechEngine: 'system'));
                          await _probe();
                        },
                        child: const Text('删除'))
                    : null,
                body: [
                  if (ttsInstalled == true)
                    DropdownButtonFormField<int>(
                      initialValue: LocalTts.voices.any((v) => v.sid == s.offlineVoiceSid) ? s.offlineVoiceSid : LocalTts.defaultSid,
                      decoration: const InputDecoration(labelText: '音色', isDense: true),
                      items: [for (final v in LocalTts.voices) DropdownMenuItem(value: v.sid, child: Text(v.name))],
                      onChanged: (v) {
                        if (v != null) app.saveSettings(app.settings.copyWith(offlineVoiceSid: v));
                      },
                    ),
                ],
              ),
              engineTile(
                'cloud',
                '云端语音合成',
                hasEndpoint ? '用「模型与 API」的端点，按字符计费；最像真人' : '先到「模型与 API」配好端点',
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
                  TextField(controller: speechVoice, decoration: const InputDecoration(labelText: '音色', hintText: 'alloy / nova / FunAudioLLM/CosyVoice2-0.5B:anna', helperText: '各家音色名不同，看服务商文档；留空用 alloy', helperMaxLines: 2)),
                  const SizedBox(height: 10),
                  TextField(controller: speechStyle, decoration: const InputDecoration(labelText: '语气说明（可选）', hintText: '温柔、慢一点', helperText: '只有 gpt-4o-mini-tts 这类认，其他会忽略', helperMaxLines: 2)),
                  const SizedBox(height: 4),
                  Text('改了模型名记得点下面「保存」再试听。', style: muted),
                ],
              ),
            ]),
          ),
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
      ),
    );
  }
}
