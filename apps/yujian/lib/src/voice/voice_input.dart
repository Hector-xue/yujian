import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'audio_bytes_native.dart' if (dart.library.js_interop) 'audio_bytes_web.dart' as audio;
import 'local_asr_native.dart' if (dart.library.js_interop) 'local_asr_web.dart';

/// 语音输入走四条路，按顺序自动降级，用户只看到一个麦克风按钮：
///  0. local   App 内录音 → 离线模型（sherpa-onnx Paraformer，下载一次 78 MB）——装了就永远走这条，不看手机系统脸色
///  1. system  系统 SpeechRecognizer（流式，免费）——国产 ROM 常常没有或秒退
///  2. intent  系统「语音识别」弹窗（RecognizerIntent）——厂商助手/输入法常有
///  3. cloud   App 内录音 → 用户配置的模型端点 /audio/transcriptions
/// 一条路失败就在同一次点击里换下一条，不让用户反复按。
enum VoiceEngine { local, system, intent, cloud }

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
  Future<void> start(
      {required void Function(String) onPartial,
      required void Function(String) onFinal,
      required void Function(VoicePhase) onPhase,
      required void Function(String) onNotice,
      void Function(String reason)? onFailed}) async {
    if (phase != VoicePhase.idle) {
      _log('start 被忽略：phase=$phase');
      return;
    }
    final order = [
      if (await LocalAsr.installed()) VoiceEngine.local,
      VoiceEngine.system,
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) VoiceEngine.intent,
      if (transcriber != null) VoiceEngine.cloud,
    ];
    final reasons = <String>[];
    if (transcriber == null) lastReport['cloud'] = '没配「语音转写模型」';
    _log('start 顺序=${order.map((e) => e.name).join('>')} 已坏=${broken.keys.map((e) => e.name).join(',')}');
    for (final e in order) {
      if (broken.containsKey(e)) {
        reasons.add('${_name(e)}：${broken[e]}');
        continue;
      }
      try {
        final ok = await switch (e) {
          VoiceEngine.local => _startRecord(VoiceEngine.local, onPhase: onPhase),
          VoiceEngine.system =>
            _startSystem(onPartial: onPartial, onFinal: onFinal, onPhase: onPhase, onNotice: onNotice, onBroken: (why) => _fallback(e, why, onPartial, onFinal, onPhase, onNotice, onFailed)),
          VoiceEngine.intent => _startIntent(onFinal: onFinal, onPhase: onPhase),
          VoiceEngine.cloud => _startRecord(VoiceEngine.cloud, onPhase: onPhase),
        };
        if (ok) {
          active = e;
          _log('引擎 ${e.name} 已开始，phase=$phase');
          return;
        }
      } catch (err) {
        _log('引擎 ${e.name} 起不来：$err');
        broken[e] = err.toString();
        reasons.add('${_name(e)}：$err');
      }
    }
    phase = VoicePhase.idle;
    onPhase(phase);
    _log('全部失败：${reasons.join('；')}');
    throw VoiceUnavailable(reasons.isEmpty ? '这台设备没有可用的语音识别' : reasons.join('；'));
  }

  /// system 引擎在 listen 之后才报错（ERROR_AUDIO/CLIENT 之类）：标坏，同一次点击里接着试下一条。
  Future<void> _fallback(VoiceEngine failed, String why, void Function(String) onPartial, void Function(String) onFinal, void Function(VoicePhase) onPhase, void Function(String) onNotice,
      void Function(String)? onFailed) async {
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

  static String _name(VoiceEngine e) => switch (e) { VoiceEngine.local => '离线识别', VoiceEngine.system => '系统语音识别', VoiceEngine.intent => '系统语音弹窗', VoiceEngine.cloud => '云端转写' };

  // system 引擎的回调：initialize 只跑一次，但每次 listen 的回调不同，所以存成字段每次覆盖，别让第一次的闭包吃掉后面的事件
  var _finished = false;
  var _gotPartial = false;
  var _userStopped = false;
  int _listenStartedMs = 0;

  /// 最近一次每条路的结论，给诊断面板看。
  final lastReport = <String, String>{};

  /// 事件流水（带时间），诊断面板里可以整段复制发给开发者。
  final log = <String>[];
  void _log(String m) {
    final t = DateTime.now();
    log.add('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 10).toString().padLeft(2, '0')} $m');
    if (log.length > 60) log.removeAt(0);
  }

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
    if (text == null) {
      // 弹窗出来了但没给结果（取消或它自己报错）：下次别再走这条
      lastReport['intent'] = '系统语音弹窗没有返回结果（被取消或它自己出错）';
      broken[VoiceEngine.intent] = 'no-result';
      onFinal('');
      return true;
    }
    lastReport['intent'] = '识别成功';
    onFinal(text);
    return true;
  }

  /// local / cloud 都是先录音：离线要 16k 单声道 WAV，云端用 AAC 省流量。
  Future<bool> _startRecord(VoiceEngine e, {required void Function(VoicePhase) onPhase}) async {
    final key = e == VoiceEngine.local ? 'local' : 'cloud';
    if (!await _recorder.hasPermission()) {
      lastReport[key] = '没有麦克风权限';
      throw VoiceUnavailable('没有麦克风权限');
    }
    final wav = e == VoiceEngine.local;
    _log('开始录音 ${wav ? 'wav16k' : 'aac'}');
    await _recorder.start(
      RecordConfig(encoder: wav ? AudioEncoder.wav : AudioEncoder.aacLc, bitRate: 64000, sampleRate: 16000, numChannels: 1),
      path: await audio.recordingPath(ext: wav ? 'wav' : 'm4a'),
    );
    lastReport[key] = '录音中';
    return true;
  }

  /// 用户再按一下：system 停止听（会触发 final）；cloud 结束录音并转写。
  Future<String?> stop({required void Function(VoicePhase) onPhase}) async {
    _log('stop 引擎=${active?.name} phase=$phase');
    switch (active) {
      case VoiceEngine.system:
        _userStopped = true;
        await _speech.stop();
        return null;
      case VoiceEngine.local:
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
          final sw = Stopwatch()..start();
          final text = await LocalAsr.transcribeWav(path);
          lastReport['local'] = text.isEmpty ? '识别为空（没录到声音？）' : '识别成功';
          _log('离线识别 ${sw.elapsedMilliseconds}ms → "${text.length > 30 ? text.substring(0, 30) : text}"');
          return text;
        } catch (e) {
          lastReport['local'] = '离线识别出错：$e';
          _log('离线识别出错：$e');
          rethrow;
        } finally {
          await audio.deleteRecording(path);
          phase = VoicePhase.idle;
          onPhase(phase);
        }
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
          final text = await transcriber!(bytes, kIsWeb ? 'voice.webm' : 'voice.m4a', kIsWeb ? 'audio/webm' : 'audio/mp4');
          lastReport['cloud'] = '转写成功';
          return text;
        } catch (e) {
          lastReport['cloud'] = '云端转写出错：$e';
          rethrow;
        } finally {
          phase = VoicePhase.idle;
          onPhase(phase);
        }
      default:
        return null;
    }
  }

  /// 上滑取消：丢掉这次录音 / 识别，不出结果。
  Future<void> cancel({required void Function(VoicePhase) onPhase}) async {
    final e = active;
    _log('cancel 引擎=${e?.name}');
    active = null;
    try {
      switch (e) {
        case VoiceEngine.system:
          _userStopped = true;
          _finished = true;
          await _speech.cancel();
        case VoiceEngine.local:
        case VoiceEngine.cloud:
          final path = await _recorder.stop();
          if (path != null) await audio.deleteRecording(path);
        default:
          break;
      }
    } catch (_) {}
    phase = VoicePhase.idle;
    onPhase(phase);
  }

  void dispose() {
    if (phase == VoicePhase.listening) _speech.stop();
    _recorder.dispose();
  }
}
