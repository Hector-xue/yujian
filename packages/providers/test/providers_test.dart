import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:providers/providers.dart';
import 'package:test/test.dart';

/// 本地假 OpenAI-compat 服务：记录请求、按脚本回复。
class FakeServer {
  late HttpServer server;
  final List<Map<String, Object?>> requests = [];
  Object? Function(Map<String, Object?> body)? handler;
  List<int>? binaryReply; // 设了就回裸二进制（audio/mpeg），模拟 /audio/speech
  String? textReply; // 设了就原样回这段文本（NDJSON / SSE 之类）
  int status = 200;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      Map<String, Object?> body;
      try {
        body = raw.isEmpty ? <String, Object?>{} : jsonDecode(raw) as Map<String, Object?>;
      } on FormatException {
        body = {'raw': raw, 'content-type': req.headers.contentType?.toString()};
      }
      requests.add({'path': req.uri.path, 'query': req.uri.query, 'method': req.method, 'auth': req.headers.value('authorization'), 'x-api-key': req.headers.value('x-api-key'), 'x-api-resource-id': req.headers.value('x-api-resource-id'), 'x-api-app-id': req.headers.value('x-api-app-id'), 'body': body});
      if (textReply != null) {
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.text;
        req.response.write(textReply);
        await req.response.close();
        return;
      }
      if (binaryReply != null && status == 200) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('audio', 'mpeg');
        req.response.add(binaryReply!);
        await req.response.close();
        return;
      }
      final reply = handler?.call(body) ?? {'error': 'no handler'}; // handler 里可能改 status，先调它
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(reply));
      await req.response.close();
    });
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}/v1';
  Future<void> stop() => server.close(force: true);
}

Map<String, Object?> chatReply(String content) => {
      'model': 'fake-1',
      'choices': [
        {'message': {'role': 'assistant', 'content': content}}
      ],
      'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
    };

void main() {
  late FakeServer s;
  setUp(() async {
    s = FakeServer();
    await s.start();
  });
  tearDown(() => s.stop());

  ProviderConfig cfg() => ProviderConfig(name: 't', type: ProviderType.openaiCompat, baseUrl: s.baseUrl, apiKey: 'k', model: 'fake-1');

  test('posts OpenAI-shaped request with bearer auth and parses reply', () async {
    s.handler = (_) => chatReply('hello');
    final r = await OpenAICompatProvider(cfg()).complete(system: 'sys', user: 'hi');
    expect(r.text, 'hello');
    expect(r.usage?.completionTokens, 5);
    final req = s.requests.single;
    expect(req['path'], '/v1/chat/completions');
    expect(req['auth'], 'Bearer k');
    final body = req['body'] as Map;
    expect(body['model'], 'fake-1');
    expect((body['messages'] as List).length, 2);
    expect(body.containsKey('response_format'), isFalse);
  });

  test('jsonMode sends response_format; falls back once on 400', () async {
    var calls = 0;
    s.handler = (body) {
      calls++;
      if (body.containsKey('response_format')) {
        s.status = 400;
        return {'error': {'message': 'response_format unsupported'}};
      }
      s.status = 200;
      return chatReply('{"a":1}');
    };
    final r = await OpenAICompatProvider(cfg()).complete(system: 's', user: 'u', jsonMode: true);
    expect(r.text, '{"a":1}');
    expect(calls, 2);
  });

  test('5xx and 429 are retryable, 401 is not', () async {
    s.handler = (_) => {'error': 'x'};
    s.status = 503;
    await expectLater(
      OpenAICompatProvider(cfg()).complete(system: 's', user: 'u'),
      throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', isTrue)),
    );
    s.status = 401;
    await expectLater(
      OpenAICompatProvider(cfg()).complete(system: 's', user: 'u'),
      throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', isFalse)),
    );
  });

  test('capability probe reports what the model can actually do', () async {
    s.handler = (body) {
      final user = ((body['messages'] as List)[1] as Map)['content'] as String;
      return chatReply(user == 'ping' ? 'OK' : '好的，结果是：```json\n{"amount": 28}\n```');
    };
    final c = await CapabilityProbe.run(OpenAICompatProvider(cfg()));
    expect(c.chat, isTrue);
    expect(c.jsonOutput, isTrue);

    s.handler = (body) {
      final user = ((body['messages'] as List)[1] as Map)['content'] as String;
      return chatReply(user == 'ping' ? 'OK' : '金额是 28 元');
    };
    final c2 = await CapabilityProbe.run(OpenAICompatProvider(cfg()));
    expect(c2.chat, isTrue);
    expect(c2.jsonOutput, isFalse);
  });

  test('extractJsonObject handles fences, prose and nested braces', () {
    expect(extractJsonObject('{"a":{"b":"}"}}'), {'a': {'b': '}'}});
    expect(extractJsonObject('前言 ```json\n{"x": [1,2]}\n``` 后记'), {'x': [1, 2]});
    expect(extractJsonObject('no json here'), isNull);
    expect(extractJsonObject('{"broken": '), isNull);
  });

  test('fromEnvironment', () {
    expect(ProviderConfig.fromEnvironment({}), isNull);
    final c = ProviderConfig.fromEnvironment({'YUJIAN_LLM_BASE_URL': 'http://x/v1', 'YUJIAN_LLM_MODEL': 'm'});
    expect(c?.model, 'm');
  });

  test('completeWithImages sends data URI content parts and vision model override', () async {
    s.handler = (_) => chatReply('{"ok":1}');
    final c = ProviderConfig(name: 't', type: ProviderType.openaiCompat, baseUrl: s.baseUrl, apiKey: 'k', model: 'text-model', visionModel: 'vision-model');
    final r = await OpenAICompatProvider(c).completeWithImages(system: 's', user: 'u', images: const [ImageInput([1, 2, 3], 'image/png')], jsonMode: true);
    expect(r.text, '{"ok":1}');
    final body = s.requests.single['body'] as Map;
    expect(body['model'], 'vision-model');
    final content = ((body['messages'] as List)[1] as Map)['content'] as List;
    expect((content[0] as Map)['type'], 'image_url');
    expect((((content[0] as Map)['image_url']) as Map)['url'], startsWith('data:image/png;base64,'));
    expect((content[1] as Map)['text'], 'u');
  });

  test('anthropic provider speaks the messages API and maps usage', () async {
    var seen = <String, Object?>{};
    s.handler = (body) {
      seen = body;
      return {'model': 'claude-x', 'content': [{'type': 'text', 'text': '{"amount": 28}'}], 'usage': {'input_tokens': 5, 'output_tokens': 3}};
    };
    final c = ProviderConfig(name: 'a', type: ProviderType.anthropic, baseUrl: s.baseUrl, apiKey: 'k', model: 'claude-x');
    final r = await AnthropicProvider(c).complete(system: 'sys', user: 'u', jsonMode: true);
    expect(r.text, '{"amount": 28}');
    expect(r.usage?.promptTokens, 5);
    expect(s.requests.single['path'], '/v1/messages');
    expect(seen['system'], contains('只输出一个 JSON'));
    expect(seen['max_tokens'], 2048);
    final probe = await CapabilityProbe.run(AnthropicProvider(c));
    expect(probe.jsonOutput, isTrue);
  });

  test('vision probe passes only when the model names the color', () async {
    s.handler = (body) {
      final content = ((body['messages'] as List)[1] as Map)['content'];
      if (content is List) return chatReply('这是一张红色的图');
      final user = ((body['messages'] as List)[1] as Map)['content'] as String;
      return chatReply(user == 'ping' ? 'OK' : '{"amount": 28}');
    };
    final c = await CapabilityProbe.run(OpenAICompatProvider(cfg()), testVision: true);
    expect(c.vision, isTrue);
    s.handler = (body) {
      final content = ((body['messages'] as List)[1] as Map)['content'];
      if (content is List) return chatReply('我看不到图片');
      return chatReply('OK');
    };
    expect((await CapabilityProbe.run(OpenAICompatProvider(cfg()), testVision: true)).vision, isFalse);
  });

  test('redaction keeps amounts, hides ids/phones/cards/emails; local endpoint detection', () {
    expect(redactForModel('午饭花了 28.5 元，订单号 2026091512345678，卡尾号 6222 0212 3456 7890'), '午饭花了 28.5 元，订单号 [编号]，卡尾号 [卡号]');
    expect(redactForModel('给 13812345678 转了 500'), '给 [手机号] 转了 500');
    expect(redactForModel('身份证 11010119900307123X 报销 300'), '身份证 [身份证] 报销 300');
    expect(redactForModel('发票寄 a.b@x.com'), '发票寄 [邮箱]');
    expect(isLocalEndpoint('http://localhost:11434/v1'), isTrue);
    expect(isLocalEndpoint('http://192.168.1.10:1234/v1'), isTrue);
    expect(isLocalEndpoint('http://10.0.0.5/v1'), isTrue);
    expect(isLocalEndpoint('https://api.openai.com/v1'), isFalse);
    expect(isLocalEndpoint('https://openrouter.ai/api/v1'), isFalse);
  });

  test('error message is pulled out of the vendor JSON envelope', () async {
    s.handler = (_) => {'error': {'message': 'The supported API model names are deepseek-flash, deepseek-v4-pro, but you passed X.', 'type': 'invalid_request_error'}};
    s.status = 400;
    await expectLater(
      OpenAICompatProvider(cfg()).complete(system: 's', user: 'u'),
      throwsA(isA<ProviderException>().having((e) => e.message, 'message', 'The supported API model names are deepseek-flash, deepseek-v4-pro, but you passed X.').having((e) => e.status, 'status', 400)),
    );
    expect(providerErrorMessage('{"message":"bad key"}'), 'bad key');
    expect(providerErrorMessage('{"error":"plain"}'), 'plain');
    expect(providerErrorMessage('<html>502</html>'), '<html>502</html>');
  });

  test('listModels reads /models for openai-compat and anthropic', () async {
    s.handler = (_) => {'object': 'list', 'data': [{'id': 'deepseek-v4-pro'}, {'id': 'deepseek-flash'}, {'id': 'deepseek-flash'}]};
    expect(await listModels(cfg()), ['deepseek-flash', 'deepseek-v4-pro']);
    expect(s.requests.last['method'], 'GET');
    expect(s.requests.last['path'], '/v1/models');
    expect(s.requests.last['auth'], 'Bearer k');
    final a = ProviderConfig(name: 'a', type: ProviderType.anthropic, baseUrl: s.baseUrl, apiKey: 'ak', model: 'm');
    s.handler = (_) => {'data': [{'id': 'claude-x', 'type': 'model'}]};
    expect(await listModels(a), ['claude-x']);
    expect(s.requests.last['x-api-key'], 'ak');
    expect(s.requests.last['auth'], isNull);
    s.handler = (_) => {'error': {'message': 'nope'}};
    s.status = 404;
    await expectLater(listModels(cfg()), throwsA(isA<ProviderException>().having((e) => e.message, 'message', 'nope')));
  });

  test('transcribeAudio posts multipart to /audio/transcriptions and returns text', () async {
    s.handler = (_) => {'text': ' 午饭花了二十八 '};
    final t = await transcribeAudio(cfg(), Uint8List.fromList([1, 2, 3, 4]), filename: 'a.m4a', mime: 'audio/mp4', model: 'whisper-1');
    expect(t, '午饭花了二十八');
    final req = s.requests.last;
    expect(req['path'], '/v1/audio/transcriptions');
    expect(req['auth'], 'Bearer k');
    expect((req['body'] as Map)['content-type'], startsWith('multipart/form-data'));
    final raw = (req['body'] as Map)['raw'] as String;
    expect(raw, contains('name="model"'));
    expect(raw, contains('whisper-1'));
    expect(raw, contains('filename="a.m4a"'));
    expect(raw, contains('name="language"'));
    final anth = ProviderConfig(name: 'a', type: ProviderType.anthropic, baseUrl: s.baseUrl, apiKey: 'ak', model: 'm');
    await expectLater(transcribeAudio(anth, Uint8List(1), filename: 'a', mime: 'audio/mp4', model: 'x'), throwsA(isA<ProviderException>()));
  });

  test('synthesizeSpeech posts JSON to /audio/speech and returns raw audio bytes; JSON-wrapped and error replies handled', () async {
    s.binaryReply = [0xFF, 0xFB, 0x90, 0x00];
    final a = await synthesizeSpeech(cfg(), '主人好呀', model: 'tts-1', voice: 'alloy', instructions: '温柔一点');
    expect(a, [0xFF, 0xFB, 0x90, 0x00]);
    final req = s.requests.last;
    expect(req['path'], '/v1/audio/speech');
    expect(req['auth'], 'Bearer k');
    expect((req['body'] as Map)['input'], '主人好呀');
    expect((req['body'] as Map)['voice'], 'alloy');
    expect((req['body'] as Map)['instructions'], '温柔一点');
    expect((req['body'] as Map)['response_format'], 'mp3');
    // 空文本不发请求
    final before = s.requests.length;
    expect(await synthesizeSpeech(cfg(), '  ', model: 'tts-1', voice: 'alloy'), isEmpty);
    expect(s.requests.length, before);
    // JSON 包着 base64
    s.binaryReply = null;
    s.handler = (_) => {'audio': base64Encode([1, 2, 3])};
    expect(await synthesizeSpeech(cfg(), 'x', model: 'tts-1', voice: 'alloy'), [1, 2, 3]);
    // 出错
    s.status = 400;
    s.handler = (_) => {'error': {'message': 'voice not found'}};
    await expectLater(synthesizeSpeech(cfg(), 'x', model: 'tts-1', voice: 'nope'), throwsA(isA<ProviderException>().having((e) => e.message, 'message', 'voice not found')));
    s.status = 200;
  });

  test('MeteredProvider reports usage per call kind and skips failed calls', () async {
    final events = <UsageEvent>[];
    final p = MeteredProvider(OpenAICompatProvider(cfg()), onUsage: events.add);
    s.handler = (_) => chatReply('hi');
    await p.complete(system: 's', user: 'u');
    expect(events.single.kind, 'chat');
    expect(events.single.promptTokens, 10);
    expect(events.single.completionTokens, 5);
    expect(events.single.hasUsage, isTrue);
    expect(events.single.model, 'fake-1');
    s.handler = (_) => {'choices': [{'message': {'role': 'assistant', 'content': 'x'}}]}; // 没 usage
    await p.completeWithImages(system: 's', user: 'u', images: [ImageInput(Uint8List(2), 'image/png')]);
    expect(events.last.kind, 'vision');
    expect(events.last.hasUsage, isFalse);
    expect(events.last.model, 'fake-1'); // 响应没 model 字段时 provider 自己填配置里的名字
    s.status = 500;
    s.handler = (_) => {'error': 'x'};
    await expectLater(p.complete(system: 's', user: 'u'), throwsA(isA<ProviderException>()));
    expect(events.length, 2);
    s.status = 200;
  });

  test('doubaoSynthesize: new-console key header, resource id, additions as string, NDJSON/SSE chunks joined; error code surfaced', () async {
    final base = 'http://127.0.0.1:${s.server.port}';
    s.textReply = '{"code":20000000,"message":"OK","data":"${base64Encode([1, 2])}"}\ndata: {"code":20000000,"data":"${base64Encode([3])}"}\n{"code":20000003,"message":"done"}\n';
    final a = await doubaoSynthesize(DoubaoTtsConfig(apiKey: 'k', voice: 'zh_female_vv_uranus_bigtts', baseUrl: base), '你好', style: '用撒娇甜蜜的语气');
    expect(a, [1, 2, 3]);
    final req = s.requests.last;
    expect(req['path'], '/api/v3/tts/unidirectional');
    expect(req['x-api-key'], 'k');
    expect(req['x-api-resource-id'], 'seed-tts-2.0');
    final rp = (req['body'] as Map)['req_params'] as Map;
    expect(rp['speaker'], 'zh_female_vv_uranus_bigtts');
    expect(rp['additions'], isA<String>());
    expect(jsonDecode(rp['additions'] as String), {'context_texts': ['用撒娇甜蜜的语气']});
    // 老账号：App ID + Access Key
    await doubaoSynthesize(DoubaoTtsConfig(appId: 'app', accessKey: 'ak', voice: 'v', baseUrl: base), 'x');
    expect(s.requests.last['x-api-app-id'], 'app');
    expect(s.requests.last['x-api-key'], isNull);
    // 错误码
    s.textReply = '{"code":45000001,"message":"invalid speaker"}\n';
    await expectLater(doubaoSynthesize(DoubaoTtsConfig(apiKey: 'k', voice: 'bad', baseUrl: base), 'x'), throwsA(isA<ProviderException>().having((e) => e.message, 'message', contains('invalid speaker'))));
    // 没配好
    await expectLater(doubaoSynthesize(const DoubaoTtsConfig(voice: 'v'), 'x'), throwsA(isA<ProviderException>()));
    s.textReply = null;
  });

  test('minimaxSynthesize: bearer, GroupId query only when given, emotion mapping, hex audio decoded; base_resp errors surfaced', () async {
    final base = 'http://127.0.0.1:${s.server.port}';
    s.handler = (_) => {'data': {'audio': '010203'}, 'base_resp': {'status_code': 0, 'status_msg': 'success'}};
    final a = await minimaxSynthesize(MiniMaxTtsConfig(apiKey: 'mk', voice: 'female-shaonv', baseUrl: base), '你好', emotion: minimaxEmotionOf('开心一点'));
    expect(a, [1, 2, 3]);
    var req = s.requests.last;
    expect(req['path'], '/v1/t2a_v2');
    expect(req['query'], '');
    expect(req['auth'], 'Bearer mk');
    expect(((req['body'] as Map)['voice_setting'] as Map)['emotion'], 'happy');
    expect((req['body'] as Map)['model'], 'speech-02-hd');
    await minimaxSynthesize(MiniMaxTtsConfig(apiKey: 'mk', groupId: 'g1', voice: 'v', baseUrl: base), 'x');
    req = s.requests.last;
    expect(req['query'], 'GroupId=g1');
    expect(((req['body'] as Map)['voice_setting'] as Map).containsKey('emotion'), isFalse);
    expect(minimaxEmotionOf('温柔、慢一点'), 'calm');
    expect(minimaxEmotionOf(''), isNull);
    s.handler = (_) => {'base_resp': {'status_code': 1004, 'status_msg': 'login fail'}};
    await expectLater(minimaxSynthesize(MiniMaxTtsConfig(apiKey: 'bad', voice: 'v', baseUrl: base), 'x'), throwsA(isA<ProviderException>().having((e) => e.message, 'message', contains('鉴权失败'))));
  });
}
