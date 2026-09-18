import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:providers/providers.dart';

import '../settings_store.dart';

/// 朗读出口：配了语音合成模型就走云端神经 TTS（有语气、像真人），否则 / 失败时退回系统 TTS。
/// 对话页只管调 [speak] / [stop]，不用知道是哪条路在响。
class SpeechOutput {
  final FlutterTts _tts = FlutterTts();
  AudioPlayer? _player;
  int _seq = 0; // 每次 speak 递增；合成回来时序号过期就不放（用户已经点了下一条 / 关了朗读）
  String? lastError; // 最近一次云端合成失败的原因（设置页「试听」用）

  /// 括号里的小动作「（甩尾巴）」不读；表情符号也去掉，念出来很怪。
  static String cleanup(String text) => text.replaceAll(RegExp(r'（[^）]{0,12}）'), '').replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '').trim();

  static bool cloudConfigured(Settings s) => (s.speechModel ?? '').isNotEmpty && s.providerConfig != null && s.providerConfig!.type != ProviderType.anthropic;

  Future<void> speak(String text, Settings settings, {bool interrupt = true}) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return;
    final my = ++_seq;
    if (interrupt) await stop();
    if (cloudConfigured(settings)) {
      final ok = await _speakCloud(clean, settings, my);
      if (ok || my != _seq) return;
      // 云端没成：退回系统 TTS，别让用户干等一句没声音
    }
    await _speakSystem(clean);
  }

  Future<bool> _speakCloud(String text, Settings s, int my) async {
    final cfg = s.providerConfig!;
    try {
      final bytes = await synthesizeSpeech(cfg, text, model: s.speechModel!, voice: (s.speechVoice ?? '').isEmpty ? 'alloy' : s.speechVoice!, instructions: s.speechStyle, timeout: const Duration(seconds: 30));
      if (my != _seq) return true; // 已经被后来的打断，静默丢弃
      if (bytes.isEmpty) return false;
      await _play(bytes);
      lastError = null;
      return true;
    } on ProviderException catch (e) {
      lastError = e.message;
      return false;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  Future<void> _play(Uint8List bytes) async {
    if (kIsWeb) return; // web 没走通（文件系统），退回系统 TTS
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, 'yujian_tts_${DateTime.now().millisecondsSinceEpoch}.mp3'));
    await f.writeAsBytes(bytes, flush: true);
    final player = _player ??= AudioPlayer();
    try {
      await player.setFilePath(f.path);
      await player.play(); // play() 在播完后才返回
    } finally {
      try {
        await f.delete();
      } catch (_) {}
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
