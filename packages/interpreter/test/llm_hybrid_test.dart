import 'package:interpreter/interpreter.dart';
import 'package:interpreter/src/corpus.dart';
import 'package:providers/providers.dart';
import 'package:test/test.dart';

/// 脚本化假模型：按 user 文本返回预设 JSON，或抛错模拟不可用。
class FakeProvider extends ChatProvider {
  final String Function(String system, String user) reply;
  int calls = 0;
  FakeProvider(this.reply);
  @override
  String get name => 'fake';
  @override
  String get model => 'fake-1';
  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async {
    calls++;
    return ChatResult(text: reply(system, user), model: 'fake-1', latency: Duration.zero);
  }
}

class VisionFake extends ChatProvider {
  List<ImageInput>? got;
  @override
  String get name => 'v';
  @override
  String get model => 'v';
  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async =>
      throw UnimplementedError();
  @override
  Future<ChatResult> completeWithImages({required String system, required String user, required List<ImageInput> images, bool jsonMode = false, Duration? timeout}) async {
    got = images;
    return ChatResult(text: '{"intent":"propose_transactions","transactions":[{"type":"expense","amount":"19.90","merchant":"瑞幸咖啡","category_id":"food","account_id":"wechat","occurred_at":"2026-09-14T12:31:00+08:00","confidence":0.9},{"type":"expense","amount":null,"description":"看不清","confidence":0.3}]}', model: 'v', latency: Duration.zero);
  }
}

class DeadProvider extends ChatProvider {
  @override
  String get name => 'dead';
  @override
  String get model => 'dead';
  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async =>
      throw ProviderException('connection refused', retryable: true);
}

void main() {
  final ctx = Corpus.load('../../corpus/cases.json').context;

  group('LLMInterpreter.parseModelJson', () {
    test('normalizes amounts, names, dates and split', () {
      final r = LLMInterpreter.parseModelJson({
        'intent': 'propose_transactions',
        'transactions': [
          {'type': 'expense', 'amount': '50.00', 'currency': 'cny', 'account_id': '微信', 'category_id': '餐饮', 'description': '与同事午餐', 'occurred_at': '2026-09-15T12:00:00', 'split': {'total': '86.00', 'share': '50.00'}, 'confidence': 0.9},
        ],
      }, ctx, modelUsed: 'm');
      final p = r.drafts.single.payload;
      expect(p['amount_minor'], 5000);
      expect(p['currency'], 'CNY');
      expect(p['account_id'], 'wechat');
      expect(p['category_id'], 'food');
      expect(p['occurred_at'], '2026-09-15T12:00:00.000+08:00'); // 无偏移按上下文时区
      expect((p['metadata'] as Map)['split'], {'total': 8600, 'share': 5000});
      expect(r.drafts.single.missing, isEmpty);
      expect(r.modelUsed, 'm');
    });

    test('unknown ids become null + missing instead of guesses', () {
      final r = LLMInterpreter.parseModelJson({
        'intent': 'propose_transactions',
        'transactions': [{'type': 'expense', 'amount': 28, 'category_id': 'snacks', 'account_id': 'paypal'}],
      }, InterpretContext(now: ctx.now, tzOffsetMinutes: 480, categories: ctx.categories, accounts: ctx.accounts));
      final d = r.drafts.single;
      expect(d.payload['category_id'], isNull);
      expect(d.payload['account_id'], isNull);
      expect(d.missing, containsAll(['category_id', 'account_id']));
      expect(d.payload['amount_minor'], 2800);
    });

    test('bad amount is reported, not silently dropped', () {
      final r = LLMInterpreter.parseModelJson({'intent': 'propose_transactions', 'transactions': [{'type': 'expense', 'amount': 'twenty'}]}, ctx);
      expect(r.drafts.single.missing, contains('amount_minor'));
      expect(r.notes.join(), contains('amount unparsable'));
    });

    test('query filter names map to ids; update resolves target from recent', () {
      final q = LLMInterpreter.parseModelJson({'intent': 'query', 'query': {'metric': 'sum', 'filter': {'category_ids': ['餐饮']}}}, ctx);
      expect(((q.query!['filter'] as Map)['category_ids'] as List), ['food']);
      final u = LLMInterpreter.parseModelJson({'intent': 'propose_update', 'target': {'amount': '28.00', 'date': '2026-09-14'}, 'patch': {'category_id': '交通'}}, ctx);
      expect(u.target?.transactionId, 't_y28');
      expect(u.patch, {'category_id': 'transport'});
      expect(u.drafts.single.payload['kind'], 'update');
      final v = LLMInterpreter.parseModelJson({'intent': 'propose_void', 'target': {'most_recent': true}, 'reason': '记错了'}, ctx);
      expect(v.target?.transactionId, 't_last');
      expect(v.drafts.single.payload['kind'], 'void');
    });

    test('system prompt carries context and rules', () {
      final s = LLMInterpreter.buildSystemPrompt(ctx);
      expect(s, contains('2026-09-15T12:00:00+08:00'));
      expect(s, contains('wechat: 微信'));
      expect(s, contains('food=餐饮'));
      expect(s, contains('楼下面馆'));
      expect(s, contains('t_y28'));
      expect(s, contains('绝不把总额记成个人支出'));
    });
  });

  group('HybridInterpreter', () {
    test('high-confidence rule result skips the model', () async {
      final fake = FakeProvider((_, __) => '{"intent":"chat"}');
      final h = HybridInterpreter(llm: LLMInterpreter(fake));
      final r = await h.interpret('昨天晚上打车花了 36 元，微信支付', ctx);
      expect(fake.calls, 0);
      expect(r.interpreter, 'hybrid');
      expect(r.drafts.single.payload['amount_minor'], 3600);
      expect(r.degraded, isFalse);
    });

    test('low-confidence rule result goes to the model and merges', () async {
      final fake = FakeProvider((_, __) => '{"intent":"propose_transactions","transactions":[{"type":"expense","amount":"1500.00","category_id":"shopping","description":"按摩仪","occurred_at":"2026-09-15T12:00:00+08:00","confidence":0.85}]}');
      final h = HybridInterpreter(llm: LLMInterpreter(fake));
      final r = await h.interpret('给妈妈买了 1.5k 的按摩仪', ctx);
      expect(fake.calls, 1);
      expect(r.modelUsed, 'fake-1');
      final p = r.drafts.single.payload;
      expect(p['amount_minor'], 150000);
      expect(p['category_id'], 'shopping');
      expect(p['account_id'], 'wechat'); // 模型没填账户，规则的默认账户补上
      expect(r.drafts.single.missing, isEmpty);
    });

    test('model amount not in text lowers confidence', () async {
      final fake = FakeProvider((_, __) => '{"intent":"propose_transactions","transactions":[{"type":"expense","amount":"1600.00","category_id":"shopping","confidence":0.9}]}');
      final r = await HybridInterpreter(llm: LLMInterpreter(fake)).interpret('给妈妈买了 1.5k 的按摩仪', ctx);
      expect(r.drafts.single.confidence, lessThan(0.6));
      expect(r.notes.join(), contains('amount cross-check failed'));
    });

    test('model unavailable degrades to rule result, never fails', () async {
      final r = await HybridInterpreter(llm: LLMInterpreter(DeadProvider())).interpret('给妈妈买了 1.5k 的按摩仪', ctx);
      expect(r.degraded, isTrue);
      expect(r.intent, Intent.proposeTransactions);
      expect(r.drafts.single.payload['amount_minor'], 150000);
      expect(r.notes.join(), contains('model unavailable'));
    });

    test('model says chat but rule found money → keep rule drafts', () async {
      final fake = FakeProvider((_, __) => '{"intent":"chat"}');
      final r = await HybridInterpreter(llm: LLMInterpreter(fake)).interpret('给妈妈买了 1.5k 的按摩仪', ctx);
      expect(r.intent, Intent.proposeTransactions);
    });

    test('no model configured', () async {
      final r = await HybridInterpreter().interpret('今天真开心', ctx);
      expect(r.intent, Intent.chat);
      expect(r.degraded, isTrue);
    });
  });

  group('VisionInterpreter', () {
    test('images go to the model; drafts normalized; confidence discounted; unreadable amount stays null', () async {
      final v = VisionFake();
      final r = await VisionInterpreter(v).interpret([const ImageInput([1, 2, 3], 'image/png')], ctx);
      expect(v.got!.single.mime, 'image/png');
      expect(r.intent, Intent.proposeTransactions);
      expect(r.interpreter, 'vision');
      expect(r.drafts.length, 2);
      expect(r.drafts[0].payload['amount_minor'], 1990);
      expect(r.drafts[0].payload['merchant'], '瑞幸咖啡');
      expect(r.drafts[0].confidence, closeTo(0.72, 0.001));
      expect(r.drafts[1].payload['amount_minor'], isNull);
      expect(r.drafts[1].missing, contains('amount_minor'));
    });

    test('provider without vision support surfaces UnsupportedError', () async {
      expect(() => VisionInterpreter(DeadProvider()).interpret([const ImageInput([], 'image/png')], ctx), throwsUnsupportedError);
    });
  });
}
