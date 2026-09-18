import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:providers/providers.dart';

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

  /// [meter] 给了就把云端合成的字符数记进用量。
  /// 按设置里选的引擎读；选的那个不可用（没配 / 出错）就退到系统朗读，别让用户干等一句没声音。
  Future<void> speak(String text, Settings settings, {bool interrupt = true, UsageMeter? meter}) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return;
    if (interrupt) await stop();
    final my = ++_seq; // 必须在 stop() 之后取号：stop() 会把旧号作废
    final ok = await _speakEngine(settings.speechEngine, clean, settings, my, meter: meter);
    if (ok || my != _seq) return;
    await _speakSystem(clean);
  }

  /// 只走指定引擎（设置页试听用），不退级。返回是否成功。
  Future<bool> speakWith(String engine, String text, Settings settings) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return false;
    await stop();
    final my = ++_seq;
    if (engine == 'system') {
      await _speakSystem(clean);
      return true;
    }
    return _speakEngine(engine, clean, settings, my);
  }

  Future<bool> _speakEngine(String engine, String clean, Settings s, int my, {UsageMeter? meter}) async {
    switch (engine) {
      case 'cloud':
        if (!cloudConfigured(s)) return false;
        final voice = (s.speechVoice ?? '').isEmpty ? 'alloy' : s.speechVoice!;
        return _speakChunked(clean, my, (sen) => synthesizeSpeech(s.providerConfig!, sen, model: s.speechModel!, voice: voice, instructions: s.speechStyle, timeout: const Duration(seconds: 30)),
            onDone: () => meter?.recordSpeech(s.speechModel!, clean.length));
      case 'doubao':
        if (!s.doubaoTts.configured) return false;
        return _speakChunked(clean, my, (sen) => doubaoSynthesize(s.doubaoTts, sen, style: s.speechStyle), onDone: () => meter?.recordSpeech('doubao-tts-2.0', clean.length));
      case 'minimax':
        if (!s.minimaxTts.configured) return false;
        return _speakChunked(clean, my, (sen) => minimaxSynthesize(s.minimaxTts, sen, emotion: minimaxEmotionOf(s.speechStyle)), onDone: () => meter?.recordSpeech('minimax/${s.minimaxModel}', clean.length));
      case 'omni':
        if (s.providerConfig == null) return false;
        return _speakChunked(clean, my, (sen) => omniSynthesize(s.providerConfig!, sen, model: s.speechModel, voice: s.omniVoice, style: s.speechStyle), onDone: () => meter?.recordSpeech('${(s.speechModel ?? '').isEmpty ? s.model : s.speechModel}', clean.length));
      default:
        return false;
    }
  }

  /// 云端合成按句切、流水线：第 1 句合成完就开播，播的同时合成第 2 句……长回复不用等整段。
  Future<bool> _speakChunked(String text, int my, Future<Uint8List> Function(String sentence) synth, {void Function()? onDone}) async {
    final sentences = splitSentences(text);
    if (sentences.isEmpty) return false;
    try {
      Future<Uint8List> next = synth(sentences.first);
      for (var i = 0; i < sentences.length; i++) {
        final bytes = await next;
        if (my != _seq) return true; // 被打断，静默丢弃
        if (i + 1 < sentences.length) next = synth(sentences[i + 1]); // 先把下一句排上再播这一句
        if (bytes.isNotEmpty) await _play(bytes);
        if (my != _seq) {
          if (i + 1 < sentences.length) next.then((_) {}, onError: (_) {});
          return true;
        }
      }
      lastError = null;
      onDone?.call();
      return true;
    } on ProviderException catch (e) {
      lastError = e.message;
      return false;
    } catch (e) {
      lastError = '$e';
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
