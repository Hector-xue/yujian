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
import 'local_tts_native.dart' if (dart.library.js_interop) 'local_tts_web.dart';

/// 朗读出口，三档：配了云端语音合成模型 → 云端；装了离线真人感语音包 → 本机 Kokoro；都没有 / 失败 → 系统 TTS。
/// 对话页只管调 [speak] / [stop]，不用知道是哪条路在响。
class SpeechOutput {
  final FlutterTts _tts = FlutterTts();
  AudioPlayer? _player;
  int _seq = 0; // 每次 speak 递增；合成回来时序号过期就不放（用户已经点了下一条 / 关了朗读）
  String? lastError; // 最近一次云端 / 离线合成失败的原因（设置页「试听」用）
  bool? _offlineInstalled; // 缓存一次，装 / 删语音包后调 [refreshOffline]

  Future<bool> offlineAvailable() async => _offlineInstalled ??= await LocalTts.installed();
  void refreshOffline() => _offlineInstalled = null;

  /// 括号里的小动作「（甩尾巴）」不读；表情符号也去掉，念出来很怪。
  static String cleanup(String text) => text.replaceAll(RegExp(r'（[^）]{0,12}）'), '').replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '').trim();

  static bool cloudConfigured(Settings s) => (s.speechModel ?? '').isNotEmpty && s.providerConfig != null && s.providerConfig!.type != ProviderType.anthropic;

  /// [meter] 给了就把云端合成的字符数记进用量。
  Future<void> speak(String text, Settings settings, {bool interrupt = true, UsageMeter? meter}) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return;
    final my = ++_seq;
    if (interrupt) await stop();
    if (cloudConfigured(settings)) {
      final ok = await _speakCloud(clean, settings, my);
      if (ok) meter?.recordSpeech(settings.speechModel!, clean.length);
      if (ok || my != _seq) return;
      // 云端没成：往下退，别让用户干等一句没声音
    }
    if (await offlineAvailable()) {
      final ok = await _speakOffline(clean, settings, my);
      if (ok || my != _seq) return;
    }
    await _speakSystem(clean);
  }

  /// 只走离线包（设置页试听用），不退回系统 TTS。
  Future<bool> speakOffline(String text, Settings settings) async {
    final clean = cleanup(text);
    if (clean.isEmpty) return false;
    final my = ++_seq;
    await stop();
    return _speakOffline(clean, settings, my);
  }

  /// 离线合成按句切：先合第一句就开播，后面的句子在工作 isolate 里接着合，听感上没有长等待。
  Future<bool> _speakOffline(String text, Settings s, int my) async {
    final sentences = splitSentences(text);
    if (sentences.isEmpty) return false;
    try {
      // 一次性把所有句子排进工作 isolate（它串行处理），这边按顺序等、逐句放
      final jobs = [for (final sen in sentences) LocalTts.synthesize(sen, sid: s.offlineVoiceSid)];
      for (final job in jobs) {
        final wav = await job;
        if (my != _seq) {
          _cleanupFile(wav);
          _drop(jobs);
          return true; // 被打断，静默丢弃
        }
        await _playFile(wav);
      }
      lastError = null;
      return true;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  static void _drop(List<Future<String>> jobs) {
    for (final j in jobs) {
      j.then(_cleanupFile, onError: (_) {});
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
    await stop(); // 离线引擎不在这里关：别的页面可能还在用，它自己闲置两分钟会卸
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}
