import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'audio_bytes_native.dart' if (dart.library.js_interop) 'audio_bytes_web.dart' as audio;

/// 语音输入走三条路，按顺序自动降级，用户只看到一个麦克风按钮：
///  1. system  系统 SpeechRecognizer（流式，免费）——国产 ROM 常常没有或 ERROR_AUDIO
///  2. intent  系统「语音识别」弹窗（RecognizerIntent）——厂商助手/输入法常有
///  3. cloud   App 内录音 → 用户配置的模型端点 /audio/transcriptions
/// 一条路失败就在同一次点击里换下一条，不让用户反复按。
enum VoiceEngine { system, intent, cloud }

enum VoicePhase { idle, listening, recording, transcribing }

class VoiceUnavailable implements Exception {
  final String reason;
  VoiceUnavailable(this.reason);
  @override
  String toString() => reason;
}

typedef Transcriber = Future<String> Function(Uint8List bytes, String filename, String mime);

class VoiceInput {
  final _speech = SpeechToText();
  final _recorder = AudioRecorder();
  static const _intent = MethodChannel('yujian/speech');

  /// 本次会话里已经证实坏掉的引擎，之后直接跳过。
  final broken = <VoiceEngine, String>{};
  VoicePhase phase = VoicePhase.idle;
  VoiceEngine? active;
  String? _locale;
  bool _speechInit = false;

  /// 有云转写就把它当兜底；null = 没配。
  Transcriber? transcriber;

  static bool get platformSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// 麦克风权限（任一引擎都要）。
  Future<bool> hasPermission() async {
    if (kIsWeb) return true;
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// 开始一次语音输入。onPartial 只有 system 引擎会给；onFinal 拿到最终文本（可能为空串）；onPhase 通知 UI 换状态。
  /// 抛 VoiceUnavailable 表示三条路都走不通，reason 是给用户看的原因。
  Future<void> start({required void Function(String) onPartial, required void Function(String) onFinal, required void Function(VoicePhase) onPhase, required void Function(String) onNotice, void Function(String reason)? onFailed}) async {
    if (phase != VoicePhase.idle) return;
    final order = [
      VoiceEngine.system,
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) VoiceEngine.intent,
      if (transcriber != null) VoiceEngine.cloud,
    ];
    final reasons = <String>[];
    if (transcriber == null) lastReport['cloud'] = '没配「语音转写模型」';
    for (final e in order) {
      if (broken.containsKey(e)) {
        reasons.add('${_name(e)}：${broken[e]}');
        continue;
      }
      try {
        final ok = await switch (e) {
          VoiceEngine.system => _startSystem(onPartial: onPartial, onFinal: onFinal, onPhase: onPhase, onNotice: onNotice, onBroken: (why) => _fallback(e, why, onPartial, onFinal, onPhase, onNotice, onFailed)),
          VoiceEngine.intent => _startIntent(onFinal: onFinal, onPhase: onPhase),
          VoiceEngine.cloud => _startCloud(onPhase: onPhase),
        };
        if (ok) {
          active = e;
          return;
        }
      } catch (err) {
        broken[e] = err.toString();
        reasons.add('${_name(e)}：$err');
      }
    }
    phase = VoicePhase.idle;
    onPhase(phase);
    throw VoiceUnavailable(reasons.isEmpty ? '这台设备没有可用的语音识别' : reasons.join('；'));
  }

  /// system 引擎在 listen 之后才报错（ERROR_AUDIO/CLIENT 之类）：标坏，同一次点击里接着试下一条。
  Future<void> _fallback(VoiceEngine failed, String why, void Function(String) onPartial, void Function(String) onFinal, void Function(VoicePhase) onPhase, void Function(String) onNotice, void Function(String)? onFailed) async {
    broken[failed] = why;
    phase = VoicePhase.idle;
    active = null;
    try {
      await start(onPartial: onPartial, onFinal: onFinal, onPhase: onPhase, onNotice: onNotice, onFailed: onFailed);
      if (active != null) onNotice('系统语音识别不可用（$why），已切到${_name(active!)}');
    } on VoiceUnavailable catch (e) {
      (onFailed ?? onNotice)(e.reason);
    }
  }

  static String _name(VoiceEngine e) => switch (e) { VoiceEngine.system => '系统语音识别', VoiceEngine.intent => '系统语音弹窗', VoiceEngine.cloud => '云端转写' };

  // system 引擎的回调：initialize 只跑一次，但每次 listen 的回调不同，所以存成字段每次覆盖，别让第一次的闭包吃掉后面的事件
  var _finished = false;
  var _gotPartial = false;
  var _userStopped = false;
  int _listenStartedMs = 0;

  /// 最近一次每条路的结论，给诊断面板看。
  final lastReport = <String, String>{};
  void Function(String)? _sysPartial;
  void Function(String)? _sysFinal;
  void Function(VoicePhase)? _sysPhase;
  void Function(String)? _sysNotice;
  void Function(String)? _sysBroken;

  Future<bool> _startSystem(
      {required void Function(String) onPartial,
      required void Function(String) onFinal,
      required void Function(VoicePhase) onPhase,
      required void Function(String) onNotice,
      required void Function(String why) onBroken}) async {
    _sysPartial = onPartial;
    _sysFinal = onFinal;
    _sysPhase = onPhase;
    _sysNotice = onNotice;
    _sysBroken = onBroken;
    _finished = false;
    if (!_speechInit) {
      final ok = await _speech.initialize(
        onStatus: (st) {
          if ((st == 'done' || st == 'notListening') && phase == VoicePhase.listening && !_finished) {
            _finished = true;
            final elapsed = DateTime.now().millisecondsSinceEpoch - _listenStartedMs;
            if (!_gotPartial && !_userStopped && elapsed < 2500) {
              // 一开始就被系统结束、一个字没听到：这台机器的识别服务是坏的（小米等常见），换下一条路
              lastReport['system'] = '开始 ${elapsed}ms 后被系统结束（$st），没有任何识别结果';
              _sysBroken?.call('ended-immediately');
              return;
            }
            // 系统说结束了但没给 final：拿最近识别到的当结果
            phase = VoicePhase.idle;
            _sysPhase?.call(phase);
            _sysFinal?.call(_speech.lastRecognizedWords);
          }
        },
        onError: (e) {
          if (_finished) return;
          _finished = true;
          final code = e.errorMsg;
          if (code == 'error_no_match' || code == 'no-speech' || code == 'error_speech_timeout') {
            phase = VoicePhase.idle;
            _sysPhase?.call(phase);
            _sysNotice?.call('没听清，再说一遍');
            return;
          }
          // 权限/音频/客户端/服务端错误：这条路在这台机器上不通
          lastReport['system'] = '系统识别报错 $code';
          _sysBroken?.call(code);
        },
      );
      if (!ok) {
        lastReport['system'] = '系统没有语音识别服务（initialize=false）';
        throw VoiceUnavailable('系统没有语音识别服务');
      }
      _speechInit = true;
      for (final l in await _speech.locales()) {
        if (l.localeId.toLowerCase().startsWith('zh')) {
          _locale = l.localeId;
          break;
        }
      }
    }
    phase = VoicePhase.listening;
    onPhase(phase);
    _gotPartial = false;
    _userStopped = false;
    _listenStartedMs = DateTime.now().millisecondsSinceEpoch;
    await _speech.listen(
      onResult: (r) {
        if (_finished) return;
        if (r.recognizedWords.isNotEmpty) _gotPartial = true;
        _sysPartial?.call(r.recognizedWords);
        if (r.finalResult) {
          _finished = true;
          phase = VoicePhase.idle;
          _sysPhase?.call(phase);
          _sysFinal?.call(r.recognizedWords);
        }
      },
      listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: true, localeId: _locale, pauseFor: const Duration(seconds: 3), listenFor: const Duration(seconds: 30)),
    );
    if (!_speech.isListening && !_finished) {
      // listen() 返回了但没真的开始听（平台层 started=false）
      _finished = true;
      lastReport['system'] = '系统识别没有开始听（listen 未启动）';
      throw VoiceUnavailable('系统识别没有开始听');
    }
    lastReport['system'] = '在听';
    return true;
  }

  Future<bool> _startIntent({required void Function(String) onFinal, required void Function(VoicePhase) onPhase}) async {
    final available = await _intent.invokeMethod<bool>('intentAvailable') ?? false;
    if (!available) {
      lastReport['intent'] = '系统没有「语音识别」弹窗（没有应用响应 RECOGNIZE_SPEECH）';
      throw VoiceUnavailable('系统没有语音弹窗');
    }
    lastReport['intent'] = '可用';
    phase = VoicePhase.listening;
    onPhase(phase);
    String? text;
    try {
      text = await _intent.invokeMethod<String>('recognizeIntent');
    } finally {
      phase = VoicePhase.idle;
      onPhase(phase);
    }
    onFinal(text ?? '');
    return true;
  }

  Future<bool> _startCloud({required void Function(VoicePhase) onPhase}) async {
    if (!await _recorder.hasPermission()) {
      lastReport['cloud'] = '没有麦克风权限';
      throw VoiceUnavailable('没有麦克风权限');
    }
    lastReport['cloud'] = '录音中';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 16000, numChannels: 1), path: await audio.recordingPath());
    phase = VoicePhase.recording;
    onPhase(phase);
    return true;
  }

  /// 用户再按一下：system 停止听（会触发 final）；cloud 结束录音并转写。
  Future<String?> stop({required void Function(VoicePhase) onPhase}) async {
    switch (active) {
      case VoiceEngine.system:
        _userStopped = true;
        await _speech.stop();
        return null;
      case VoiceEngine.cloud:
        final path = await _recorder.stop();
        active = null;
        if (path == null) {
          phase = VoicePhase.idle;
          onPhase(phase);
          return '';
        }
        phase = VoicePhase.transcribing;
        onPhase(phase);
        try {
          final bytes = await audio.readRecording(path);
          if (bytes.length < 2000) return ''; // 没录到东西
          return await transcriber!(bytes, kIsWeb ? 'voice.webm' : 'voice.m4a', kIsWeb ? 'audio/webm' : 'audio/mp4');
        } finally {
          phase = VoicePhase.idle;
          onPhase(phase);
        }
      default:
        return null;
    }
  }

  void dispose() {
    if (phase == VoicePhase.listening) _speech.stop();
    _recorder.dispose();
  }
}
