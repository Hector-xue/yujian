import 'package:flutter_test/flutter_test.dart';
import 'package:yujian/src/voice/voice_input.dart';

/// 假录音机：不碰插件，只记调用。
class _FakeRecorder implements RecorderPort {
  bool recording = false;
  int starts = 0;
  bool permission = true;
  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<bool> isRecording() async => recording;
  @override
  Future<void> start({required bool wav, required String path}) async {
    if (recording) throw StateError('already recording');
    recording = true;
    starts++;
  }

  @override
  Future<String?> stop() async {
    if (!recording) return null;
    recording = false;
    return '/tmp/fake.wav';
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VoiceInput make(_FakeRecorder r, {String text = '午饭二十八'}) =>
      VoiceInput(recorder: r, localInstalled: () async => true, localTranscribe: (_) async => text, recordingPath: ({required String ext}) async => '/tmp/fake.$ext');

  test('offline engine: start enters recording phase, stop transcribes (0.6.0 regression)', () async {
    final r = _FakeRecorder();
    final v = make(r);
    final phases = <VoicePhase>[];
    await v.start(onPartial: (_) {}, onFinal: (_) {}, onPhase: phases.add, onNotice: (_) {});
    expect(v.active, VoiceEngine.local);
    expect(v.phase, VoicePhase.recording, reason: '0.6.0 把 phase=recording 弄丢了，UI 以为没开始');
    expect(phases, [VoicePhase.recording]);
    expect(r.recording, isTrue);

    final text = await v.stop(onPhase: phases.add);
    expect(text, '午饭二十八');
    expect(v.phase, VoicePhase.idle);
    expect(phases, [VoicePhase.recording, VoicePhase.transcribing, VoicePhase.idle]);
    expect(r.recording, isFalse);
  });

  test('a leftover recording is stopped before starting a new one', () async {
    final r = _FakeRecorder()..recording = true;
    final v = make(r);
    await v.start(onPartial: (_) {}, onFinal: (_) {}, onPhase: (_) {}, onNotice: (_) {});
    expect(v.phase, VoicePhase.recording);
    expect(r.starts, 1);
  });

  test('cancel drops the recording without a result', () async {
    final r = _FakeRecorder();
    final v = make(r);
    await v.start(onPartial: (_) {}, onFinal: (_) {}, onPhase: (_) {}, onNotice: (_) {});
    await v.cancel(onPhase: (_) {});
    expect(v.phase, VoicePhase.idle);
    expect(v.active, isNull);
    expect(r.recording, isFalse);
  });

  test('no microphone permission → offline engine is reported broken', () async {
    final r = _FakeRecorder()..permission = false;
    final v = VoiceInput(recorder: r, localInstalled: () async => true, localTranscribe: (_) async => '', recordingPath: ({required String ext}) async => '/tmp/x.$ext');
    // 后面的 system 引擎会去碰插件（测试里没有）→ 抛；只断言 local 这条路的结论
    try {
      await v.start(onPartial: (_) {}, onFinal: (_) {}, onPhase: (_) {}, onNotice: (_) {});
    } catch (_) {}
    expect(v.broken[VoiceEngine.local], contains('麦克风'));
    expect(v.lastReport['local'], '没有麦克风权限');
  });
}
