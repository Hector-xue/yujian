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
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, Object?>;
      requests.add({'path': req.uri.path, 'auth': req.headers.value('authorization'), 'body': body});
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
}
