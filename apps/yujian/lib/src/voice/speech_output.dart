import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:providers/providers.dart';

import '../privacy/net_log.dart';
import '../settings_store.dart';
import '../usage/usage_meter.dart';

/// 朗读出口：按设置选的引擎读（豆包 / MiniMax / OpenAI 兼容 / Omni 主模型），不可用或失败 → 系统 TTS。
/// 对话页只管调 [speak] / [stop]，不用知道是哪条路在响。
class SpeechOutput {
  final FlutterTts _tts = FlutterTts();
  AudioPlayer? _player;
  int _seq = 0; // 每次 speak 递增；合成回来时序号过期就不放（用户已经点了下一条 / 关了朗读）
  String? lastError; // 最近一次云端合成失败的原因（设置页「试听」用）

  /// 括号里的小动作「（甩尾巴）」不读；表情符号也去掉，念出来很怪。
  static String cleanup(String text) => text.replaceAll(RegExp(r'（[^）]{0,12}）'), '').replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '').trim();

  static bool cloudConfigured(Settings s) => (s.speechModel ?? '').isNotEmpty && s.providerConfig != null && s.providerConfig!.type != ProviderType.anthropic;

  /// [meter] 给了就把云端合成的字符数记进用量；[log] 给了每次云端合成进出网记录。
  /// 按设置里选的引擎读（纯本地模式下一律系统朗读）；选的那个不可用（没配 / 出错）就退到系统朗读，别让用户干等一句没声音。
  Future<void> speak(String text, Settings settings, {bool interrupt = true, UsageMeter? meter, NetLog? log}) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return;
    if (interrupt) await stop();
    final my = ++_seq; // 必须在 stop() 之后取号：stop() 会把旧号作废
    final ok = await _speakEngine(settings.effectiveSpeechEngine, clean, settings, my, meter: meter, log: log);
    if (ok || my != _seq) return;
    await _speakSystem(clean);
  }

  /// 只走指定引擎（设置页试听用），不退级。返回是否成功。
  Future<bool> speakWith(String engine, String text, Settings settings, {NetLog? log}) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return false;
    await stop();
    final my = ++_seq;
    if (engine == 'system') {
      await _speakSystem(clean);
      return true;
    }
    return _speakEngine(engine, clean, settings, my, log: log);
  }

  Future<bool> _speakEngine(String engine, String clean, Settings s, int my, {UsageMeter? meter, NetLog? log}) async {
    if (s.offlineMode && engine != 'system') {
      lastError = '纯本地模式下不用云端语音（更多 → 隐私 可关掉）';
      return false;
    }
    switch (engine) {
      case 'cloud':
        if (!cloudConfigured(s)) return false;
        final voice = (s.speechVoice ?? '').isEmpty ? 'alloy' : s.speechVoice!;
        return _speakChunked(clean, my, (sen) => synthesizeSpeech(s.providerConfig!, sen, model: s.speechModel!, voice: voice, instructions: s.speechStyle, timeout: const Duration(seconds: 30)),
            onDone: () => meter?.recordSpeech(s.speechModel!, clean.length), log: log, model: s.speechModel!, host: hostOf(s.baseUrl));
      case 'doubao':
        if (!s.doubaoTts.configured) return false;
        return _speakChunked(clean, my, (sen) => doubaoSynthesize(s.doubaoTts, sen, style: s.speechStyle), onDone: () => meter?.recordSpeech('doubao-tts-2.0', clean.length), log: log, model: 'doubao-tts-2.0', host: hostOf(s.doubaoTts.baseUrl));
      case 'minimax':
        if (!s.minimaxTts.configured) return false;
        return _speakChunked(clean, my, (sen) => minimaxSynthesize(s.minimaxTts, sen, emotion: minimaxEmotionOf(s.speechStyle)), onDone: () => meter?.recordSpeech('minimax/${s.minimaxModel}', clean.length), log: log, model: 'minimax/${s.minimaxModel}', host: hostOf(s.minimaxTts.baseUrl));
      case 'omni':
        if (s.providerConfig == null) return false;
        final model = (s.speechModel ?? '').isEmpty ? s.model! : s.speechModel!;
        return _speakChunked(clean, my, (sen) => omniSynthesize(s.providerConfig!, sen, model: s.speechModel, voice: s.omniVoice, style: s.speechStyle), onDone: () => meter?.recordSpeech(model, clean.length), log: log, model: model, host: hostOf(s.baseUrl));
      default:
        return false;
    }
  }

  /// 云端合成按句切、流水线：第 1 句合成完就开播，播的同时合成第 2 句……长回复不用等整段。
  /// 整段（不管几句）在出网记录里记一行：发了多少字、去了哪、成没成。
  Future<bool> _speakChunked(String text, int my, Future<Uint8List> Function(String sentence) synth, {void Function()? onDone, NetLog? log, String? model, String host = ''}) async {
    final sentences = splitSentences(text);
    if (sentences.isEmpty) return false;
    final sw = Stopwatch()..start();
    var sent = 0; // 已经发出去的句子数：被打断也要如实记「发了几句」
    void note({bool ok = true, String? error}) => log?.record(kind: 'speech', purpose: 'tts', host: host, model: model, chars: sentences.take(sent).fold(0, (a, b) => a + b.length), ok: ok, error: error, ms: sw.elapsedMilliseconds);
    try {
      Future<Uint8List> next = synth(sentences.first);
      sent = 1;
      for (var i = 0; i < sentences.length; i++) {
        final bytes = await next;
        if (my != _seq) {
          note();
          return true; // 被打断，静默丢弃
        }
        if (i + 1 < sentences.length) {
          next = synth(sentences[i + 1]); // 先把下一句排上再播这一句
          sent = i + 2;
        }
        if (bytes.isNotEmpty) await _play(bytes);
        if (my != _seq) {
          if (i + 1 < sentences.length) next.then((_) {}, onError: (_) {});
          note();
          return true;
        }
      }
      lastError = null;
      onDone?.call();
      note();
      return true;
    } on ProviderException catch (e) {
      lastError = e.message;
      note(ok: false, error: e.message);
      return false;
    } catch (e) {
      lastError = '$e';
      note(ok: false, error: '$e');
      return false;
    }
  }

  static void _cleanupFile(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  /// 按句号 / 问号 / 感叹号 / 换行切句；太短的碎片并到前一句，别让模型合成"。"这种。
  static List<String> splitSentences(String text) {
    final parts = text.split(RegExp(r'(?<=[。！？!?\n])'));
    final out = <String>[];
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      if (out.isNotEmpty && t.length < 4) {
        out[out.length - 1] = '${out.last}$t';
      } else {
        out.add(t);
      }
    }
    return out;
  }

  Future<void> _play(Uint8List bytes) async {
    if (kIsWeb) return; // web 没走通（文件系统），退回系统 TTS
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, 'yujian_tts_${DateTime.now().millisecondsSinceEpoch}.mp3'));
    await f.writeAsBytes(bytes, flush: true);
    await _playFile(f.path);
  }

  /// 放一个音频文件，放完删掉。
  Future<void> _playFile(String path) async {
    final player = _player ??= AudioPlayer();
    try {
      await player.setFilePath(path);
      await player.play(); // play() 在播完后才返回
    } finally {
      _cleanupFile(path);
    }
  }

  Future<void> _speakSystem(String text) async {
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.speak(text);
    } catch (_) {
      // 没有 TTS 引擎：静默
    }
  }

  Future<void> stop() async {
    _seq++;
    try {
      await _player?.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}
