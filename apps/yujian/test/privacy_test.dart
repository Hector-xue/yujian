import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/notifications/screenshot_source.dart';
import 'package:yujian/src/privacy/net_log.dart';
import 'package:yujian/src/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // 安全存储 / 截图通道走 MethodChannel，没绑定会直接炸而不是 MissingPluginException
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('net log', () {
    test('records model calls (incl. failures) with purpose, tokens, sizes; explains in plain words', () {
      final log = NetLog()..now = () => DateTime(2026, 9, 20, 14, 30);
      log.recordCall(
        const ProviderCall(model: 'deepseek-flash', kind: 'chat', purpose: 'interpret', promptTokens: 812, completionTokens: 96, hasUsage: true, systemChars: 900, userChars: 12, imageCount: 0, imageBytes: 0, ok: true, error: null, latency: Duration(milliseconds: 420)),
        host: 'api.deepseek.com',
        redacted: true,
      );
      log.recordCall(
        const ProviderCall(model: 'qwen-vl', kind: 'vision', purpose: 'shot_image', promptTokens: 0, completionTokens: 0, hasUsage: false, systemChars: 50, userChars: 0, imageCount: 1, imageBytes: 204800, ok: false, error: '401', latency: Duration(milliseconds: 90)),
        host: 'api.siliconflow.cn',
        redacted: true,
      );
      expect(log.length, 2);
      final e = log.events.last; // 最新在前，所以 last 是第一条
      expect(e.kind, 'chat');
      expect(e.tokensIn, 812);
      expect(e.chars, 912);
      expect(e.title, '对话模型 · deepseek-flash');
      expect(e.explain(), contains('已打码'));
      expect(e.explain(), contains('api.deepseek.com'));
      expect(e.explain(), contains('最近 10 笔'));
      final f = log.events.first;
      expect(f.ok, isFalse);
      expect(f.count, 1);
      expect(f.explain(), contains('发原图'));
      expect(f.explain(), contains('200 KB'));
    });

    test('every kind has a plain-language explanation naming the destination', () {
      const host = 'h.example';
      for (final (kind, purpose) in [('chat', 'interpret'), ('chat', 'companion'), ('chat', 'reply'), ('chat', 'shot_text'), ('chat', 'probe'), ('vision', 'image'), ('vision', 'shot_image'), ('transcribe', 'asr'), ('speech', 'tts'), ('models', 'list'), ('sync', 'sync'), ('sync', 'backup'), ('sync', 'restore'), ('sync', 'ping'), ('update', 'check'), ('download', 'apk'), ('download', 'asr_model')]) {
        final e = NetEvent(atMs: 0, kind: kind, purpose: purpose, host: host);
        expect(e.explain(), contains(host), reason: '$kind/$purpose');
        expect(e.explain().length, greaterThan(10), reason: '$kind/$purpose');
        expect(NetEvent.kindName(kind), isNot(kind), reason: '$kind 没有中文名');
      }
      // 「回应」那条明确说不含原话；「更新」那条明确说不带账本
      expect(const NetEvent(atMs: 0, kind: 'chat', purpose: 'reply', host: host).explain(), contains('不含你的原话'));
      expect(const NetEvent(atMs: 0, kind: 'update', purpose: 'check', host: host).explain(), contains('不带任何账本数据'));
    });

    test('track wraps success and failure; persists and reloads; caps at 500', () async {
      final log = NetLog();
      final r = await log.track(() async => [1, 2, 3], kind: 'models', purpose: 'list', host: 'x.example', countOf: (r) => r.length);
      expect(r, [1, 2, 3]);
      expect(log.events.single.count, 3);
      await expectLater(log.track(() async => throw StateError('boom'), kind: 'sync', purpose: 'ping', host: 'y.example'), throwsStateError);
      expect(log.events.first.ok, isFalse);
      expect(log.events.first.error, contains('boom'));
      for (var i = 0; i < 600; i++) {
        log.record(kind: 'update', purpose: 'check', host: 'z.example');
      }
      expect(log.length, NetLog.cap);
      await log.flush();
      final again = NetLog();
      await again.load();
      expect(again.length, NetLog.cap);
      expect(again.events.first.host, 'z.example');
      await again.clear();
      expect(again.length, 0);
      final third = NetLog();
      await third.load();
      expect(third.length, 0);
    });

    test('hostOf keeps only the host', () {
      expect(hostOf('https://api.deepseek.com/v1'), 'api.deepseek.com');
      expect(hostOf('http://192.168.1.2:11434/v1?key=secret'), '192.168.1.2');
      expect(hostOf('api.minimaxi.com'), 'api.minimaxi.com');
      expect(hostOf(null), '');
      expect(hostOf(''), '');
    });
  });

  group('offline mode', () {
    test('settings: blocks provider (even LAN), cloud voice, text/image screenshot modes and sync; config itself kept', () {
      const s = Settings(baseUrl: 'http://192.168.1.2:11434/v1', model: 'qwen', apiKey: 'k', transcribeModel: 'whisper', speechEngine: 'doubao', screenshotMode: 'image', syncUrl: 'https://s.example', syncToken: 't');
      expect(s.providerConfig, isNotNull);
      expect(s.syncActive, isTrue);
      final off = s.copyWith(offlineMode: true);
      expect(off.providerConfig, isNull);
      expect(off.modelFilled, isTrue); // 配置还在
      expect(off.effectiveSpeechEngine, 'system');
      expect(off.effectiveTranscribeModel, isNull);
      expect(off.effectiveScreenshotMode, 'local');
      expect(off.syncActive, isFalse);
      expect(off.syncConfigured, isTrue);
      // 关掉就恢复
      final back = off.copyWith(offlineMode: false);
      expect(back.providerConfig?.model, 'qwen');
      expect(back.effectiveSpeechEngine, 'doubao');
    });

    test('persists through the platform store; old installs default to off', () async {
      final store = PlatformSettingsStore();
      expect((await store.load()).offlineMode, isFalse);
      await store.save(const Settings(offlineMode: true, baseUrl: 'https://api.deepseek.com/v1', model: 'm'));
      final loaded = await store.load();
      expect(loaded.offlineMode, isTrue);
      expect(loaded.baseUrl, 'https://api.deepseek.com/v1');
      expect(loaded.providerConfig, isNull);
    });

    test('app state: no model, no companion, no sync, no auto update check; screenshot image mode falls back to local', () async {
      final src = FakeScreenshotSource()
        ..images['content://shot/1'] = Uint8List.fromList([1])
        ..ocrLines['content://shot/1'] = const [OcrLine('支付成功', height: 40), OcrLine('¥36.50', height: 90), OcrLine('肯德基', height: 30)];
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), screenshots: src)..bootstrap();
      await st.saveSettings(const Settings(baseUrl: 'https://api.deepseek.com/v1', model: 'm', apiKey: 'k', screenshotWanted: true, screenshotMode: 'image', syncUrl: 'https://s.example', syncToken: 't'));
      expect(st.hasModel, isTrue);
      expect(st.sync, isNotNull);
      await st.setOfflineMode(true);
      expect(st.hasModel, isFalse);
      expect(st.provider, isNull);
      expect(st.interpreter.llm, isNull);
      expect(st.companion, isNull);
      expect(st.shotVision, isNull);
      expect(st.sync, isNull);
      expect(await st.checkUpdate(), isNull);
      expect(st.netLog.length, 0); // 没有任何出网
      // 「发原图」档在纯本地模式下走本机 OCR
      expect(await st.ingestScreenshots([ScreenshotEvent(id: 1, uri: 'content://shot/1', name: 'Screenshot_1.png', addedMs: DateTime.now().millisecondsSinceEpoch)]), 1);
      expect(((st.inbox.single.payload['metadata'] as Map)['screenshot'] as Map)['how'], 'ocr:local');
      expect(st.netLog.length, 0);
      // 记账本身不受影响：规则解析照常
      final r = await st.say('午饭花了28元');
      expect(r.drafts.single.payload['amount_minor'], 2800);
      expect(st.netLog.length, 0);
      await st.setOfflineMode(false);
      expect(st.hasModel, isTrue);
      expect(st.sync, isNotNull);
    });

    test('metered providers are tagged per consumer so the log can tell interpret / companion / reply / vision apart', () async {
      final st = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
      await st.saveSettings(const Settings(baseUrl: 'http://127.0.0.1:1/v1', model: 'm', apiKey: 'k'));
      expect(st.provider, isA<MeteredProvider>());
      expect((st.provider as MeteredProvider).purpose, 'interpret');
      // 端点连不上：调用失败，但出网记录里必须有这一行（数据已经发出去了）
      await expectLater(st.provider!.complete(system: 's', user: 'u'), throwsA(isA<ProviderException>()));
      expect(st.netLog.length, 1);
      final e = st.netLog.events.single;
      expect(e.ok, isFalse);
      expect(e.purpose, 'interpret');
      expect(e.host, '127.0.0.1');
      expect(e.redacted, isTrue);
      expect(e.chars, 2);
    });
  });
}
