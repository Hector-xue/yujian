import 'dart:convert';
import 'dart:io';

import 'package:providers/providers.dart';
import 'package:test/test.dart';

/// 本地假 OpenAI-compat 服务：记录请求、按脚本回复。
class FakeServer {
  late HttpServer server;
  final List<Map<String, Object?>> requests = [];
  Object? Function(Map<String, Object?> body)? handler;
  int status = 200;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final body = raw.isEmpty ? <String, Object?>{} : jsonDecode(raw) as Map<String, Object?>;
      requests.add({'path': req.uri.path, 'method': req.method, 'auth': req.headers.value('authorization'), 'x-api-key': req.headers.value('x-api-key'), 'body': body});
      final reply = handler?.call(body) ?? {'error': 'no handler'};
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
}
