import 'package:flutter/material.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../voice/local_asr_native.dart' if (dart.library.js_interop) '../voice/local_asr_web.dart';
import '../voice/local_tts_native.dart' if (dart.library.js_interop) '../voice/local_tts_web.dart';
import '../voice/offline_asr_sheet.dart';
import '../voice/speech_output.dart';
import '../widgets/model_picker.dart';

/// 语音：听（离线识别包 / 云端转写）和说（离线真人感语音包 / 云端合成）。云端两项用「模型与 API」里的同一个端点。
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
  String? cloudResult;
  String? offlineResult;
  var cloudTesting = false;
  var offlineTesting = false;
  var listing = false;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context).settings;
    transcribeModel = TextEditingController(text: s.transcribeModel ?? '');
    speechModel = TextEditingController(text: s.speechModel ?? '');
    speechVoice = TextEditingController(text: s.speechVoice ?? '');
    speechStyle = TextEditingController(text: s.speechStyle ?? '');
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

  Future<void> _testCloud() async {
    final d = _draft();
    if (!SpeechOutput.cloudConfigured(d)) {
      setState(() => cloudResult = d.providerConfig == null ? '先到「模型与 API」配好端点' : '先填语音合成模型');
      return;
    }
    setState(() {
      cloudTesting = true;
      cloudResult = null;
    });
    await _preview.speak('主人好呀，今天想记点什么？', d);
    if (!mounted) return;
    setState(() {
      cloudTesting = false;
      cloudResult = _preview.lastError == null ? '合成成功，已播放' : '合成失败：${_preview.lastError}';
    });
  }

  Future<void> _testOffline() async {
    setState(() {
      offlineTesting = true;
      offlineResult = null;
    });
    final ok = await _preview.speakOffline('主人好呀，今天想记点什么？', AppScope.of(context).settings);
    if (!mounted) return;
    setState(() {
      offlineTesting = false;
      offlineResult = ok ? '合成成功，已播放' : '合成失败：${_preview.lastError}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final hasEndpoint = app.settings.providerConfig != null;
    return Scaffold(
      appBar: AppBar(title: const Text('语音')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('听你说', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('默认用手机系统的语音识别；国产 ROM 上那条路常常是死的，装离线包或配云端转写都能解决。', style: theme.textTheme.bodySmall),
          if (LocalAsr.supported)
            FutureBuilder<bool>(
              future: LocalAsr.installed(),
              builder: (ctx, snap) {
                final on = snap.data == true;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(on ? Icons.offline_pin : Icons.download_for_offline_outlined, color: theme.colorScheme.primary),
                  title: const Text('离线语音包（识别）'),
                  subtitle: Text(on ? '已安装。说话在本机识别，不联网' : '约 ${LocalAsr.approxMb} MB，下载一次', style: theme.textTheme.bodySmall),
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
          const SizedBox(height: 8),
          TextField(
            controller: transcribeModel,
            enabled: hasEndpoint,
            decoration: InputDecoration(
              labelText: '云端转写模型（可选）',
              hintText: '如 whisper-1、FunAudioLLM/SenseVoiceSmall',
              helperText: hasEndpoint ? '余见自己录音，发到「模型与 API」里那个端点的 /audio/transcriptions 转成文字' : '先到「模型与 API」配好端点',
              helperMaxLines: 2,
              suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listing || !hasEndpoint ? null : () => _pick(transcribeModel), icon: const Icon(Icons.list_alt_outlined)),
            ),
          ),
          const SizedBox(height: 24),
          Text('它说话', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('优先级：云端语音合成 → 离线真人感语音包 → 手机系统朗读。前两个有语气有语调，系统朗读机械感重。', style: theme.textTheme.bodySmall),
          if (LocalTts.supported)
            FutureBuilder<bool>(
              future: LocalTts.installed(),
              builder: (ctx, snap) {
                final on = snap.data == true;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(on ? Icons.record_voice_over : Icons.record_voice_over_outlined, color: theme.colorScheme.primary),
                    title: const Text('离线真人感语音包'),
                    subtitle: Text(on ? '已安装。在本机合成，不联网、不花 API 钱' : '约 ${LocalTts.approxMb} MB，下载一次；不想花 API 钱又嫌系统朗读机械的选它', style: theme.textTheme.bodySmall),
                    trailing: on
                        ? TextButton(
                            onPressed: () async {
                              await LocalTts.uninstall();
                              _preview.refreshOffline();
                              if (mounted) setState(() {});
                            },
                            child: const Text('删除'))
                        : FilledButton.tonal(
                            onPressed: () async {
                              await showOfflineTtsDownload(context);
                              _preview.refreshOffline();
                              if (mounted) setState(() {});
                            },
                            child: const Text('下载')),
                  ),
                  if (on)
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: LocalTts.voices.any((v) => v.sid == app.settings.offlineVoiceSid) ? app.settings.offlineVoiceSid : LocalTts.defaultSid,
                          decoration: const InputDecoration(labelText: '音色', isDense: true),
                          items: [for (final v in LocalTts.voices) DropdownMenuItem(value: v.sid, child: Text(v.name))],
                          onChanged: (v) {
                            if (v != null) app.saveSettings(app.settings.copyWith(offlineVoiceSid: v));
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(onPressed: offlineTesting ? null : _testOffline, icon: const Icon(Icons.volume_up_outlined, size: 18), label: Text(offlineTesting ? '合成中…' : '试听')),
                    ]),
                  if (on && offlineResult != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(offlineResult!, style: theme.textTheme.bodySmall)),
                ]);
              },
            ),
          const SizedBox(height: 12),
          TextField(
            controller: speechModel,
            enabled: hasEndpoint,
            decoration: InputDecoration(
              labelText: '云端语音合成模型（可选）',
              hintText: '如 gpt-4o-mini-tts、tts-1、FunAudioLLM/CosyVoice2-0.5B',
              helperText: hasEndpoint ? '回复发到同一端点的 /audio/speech 合成后播放；按字符计费' : '先到「模型与 API」配好端点',
              helperMaxLines: 2,
              suffixIcon: IconButton(tooltip: '从端点拉模型列表', onPressed: listing || !hasEndpoint ? null : () => _pick(speechModel), icon: const Icon(Icons.list_alt_outlined)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: speechVoice,
            enabled: hasEndpoint,
            decoration: const InputDecoration(labelText: '音色', hintText: 'alloy / nova / FunAudioLLM/CosyVoice2-0.5B:anna', helperText: '各家音色名不同，看服务商文档；留空用 alloy', helperMaxLines: 2),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: speechStyle,
            enabled: hasEndpoint,
            decoration: const InputDecoration(labelText: '语气说明（可选）', hintText: '温柔、慢一点，像在陪人聊天', helperText: '只有 gpt-4o-mini-tts 这类支持语气指令的模型认，其他服务会忽略', helperMaxLines: 2),
          ),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(onPressed: cloudTesting || !hasEndpoint ? null : _testCloud, icon: const Icon(Icons.volume_up_outlined, size: 18), label: Text(cloudTesting ? '合成中…' : '试听云端')),
            const SizedBox(width: 12),
            if (cloudResult != null) Expanded(child: Text(cloudResult!, style: theme.textTheme.bodySmall)),
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
