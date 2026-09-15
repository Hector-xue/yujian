import 'package:interpreter/interpreter.dart';
import 'package:interpreter/src/corpus.dart';
import 'package:test/test.dart';

void main() {
  group('extractAmounts', () {
    test('arabic with units and verbs', () {
      expect(extractAmounts('午饭花了28元').single.minor, 2800);
      expect(extractAmounts('星巴克 32').single.minor, 3200);
      expect(extractAmounts('外卖 32.5').single.minor, 3250);
      expect(extractAmounts('1,234.56 元').single.minor, 123456);
      expect(extractAmounts('买了 1.5k 的按摩仪').single.minor, 150000);
      expect(extractAmounts('房子 1.2万').single.minor, 1200000);
      expect(extractAmounts('¥58').single.minor, 5800);
      expect(extractAmounts(r'$20 的域名').single.currency, 'USD');
      expect(extractAmounts('1200日元').single.minor, 1200);
    });
    test('chinese numerals need a money cue', () {
      expect(extractAmounts('三十五块').single.minor, 3500);
      expect(extractAmounts('二十八块五').single.minor, 2850);
      expect(extractAmounts('三块五毛').single.minor, 350);
      expect(extractAmounts('花了两百五').single.minor, 25000);
      expect(extractAmounts('花了一千二').single.minor, 120000);
      expect(extractAmounts('花了三万').single.minor, 3000000);
      expect(extractAmounts('上周三加油'), isEmpty);
      expect(extractAmounts('三个人'), isEmpty);
      expect(extractAmounts('AA 一共 240').single.minor, 24000);
    });
    test('dates, times, counts are not money', () {
      expect(extractAmounts('9月15日'), isEmpty);
      expect(extractAmounts('12:30 买了杯咖啡 18').single.minor, 1800);
      expect(extractAmounts('3 个人吃了 150').single.minor, 15000);
      expect(extractAmounts('分 12 期'), isEmpty);
      expect(extractAmounts('299 一年').single.minor, 29900);
      expect(extractAmounts('打 8 折'), isEmpty);
      expect(extractAmounts('3.1415'), isEmpty);
    });
    test('parseChineseInt', () {
      expect(parseChineseInt('十'), 10);
      expect(parseChineseInt('十五'), 15);
      expect(parseChineseInt('二十八'), 28);
      expect(parseChineseInt('两百五'), 250);
      expect(parseChineseInt('三百二十'), 320);
      expect(parseChineseInt('一千零五'), 1005);
      expect(parseChineseInt('一万二'), 12000);
      expect(parseChineseInt('三万五千'), 35000);
      expect(parseChineseInt('abc'), isNull);
    });
  });

  group('extractDateTime', () {
    final now = DateTime.utc(2026, 9, 15, 12, 0); // 周二 墙上时间
    String d(DateTime w) => '${w.year}-${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')} ${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
    test('relative days and periods', () {
      expect(d(extractDateTime('昨天晚上打车', now).wall), '2026-09-14 19:00');
      expect(d(extractDateTime('前天 KTV', now).wall), '2026-09-13 12:00');
      expect(d(extractDateTime('昨晚吃火锅', now).wall), '2026-09-14 19:00');
      expect(d(extractDateTime('今早地铁', now).wall), '2026-09-15 08:00');
      expect(d(extractDateTime('中午外卖', now).wall), '2026-09-15 12:00');
      expect(d(extractDateTime('午饭', now).wall), '2026-09-15 12:00'); // 无日期词 → 当下
      expect(extractDateTime('午饭', now).explicitDate, isFalse);
    });
    test('weekday, month-day, N days ago, clock', () {
      expect(d(extractDateTime('上周三加油', now).wall), '2026-09-09 12:00');
      expect(d(extractDateTime('周一买菜', now).wall), '2026-09-14 12:00');
      expect(d(extractDateTime('周五聚餐', now).wall), '2026-09-11 12:00'); // 未来的周五 → 上周五
      expect(d(extractDateTime('9月10号物业费', now).wall), '2026-09-10 12:00');
      expect(d(extractDateTime('12月25日', now).wall), '2025-12-25 12:00'); // 未来月日 → 去年
      expect(d(extractDateTime('3天前', now).wall), '2026-09-12 12:00');
      expect(d(extractDateTime('昨天下午三点半', now).wall), '2026-09-14 15:30');
      expect(d(extractDateTime('12:30 咖啡', now).wall), '2026-09-15 12:30');
      expect(d(extractDateTime('上个月5号', now).wall), '2026-08-05 12:00');
      expect(d(extractDateTime('8号发工资', now).wall), '2026-09-08 12:00');
    });
    test('query ranges', () {
      expect(extractRange('这个月', now), (from: '2026-09-01', to: '2026-09-30'));
      expect(extractRange('上个月', now), (from: '2026-08-01', to: '2026-08-31'));
      expect(extractRange('这周', now), (from: '2026-09-14', to: '2026-09-15'));
      expect(extractRange('上周', now), (from: '2026-09-07', to: '2026-09-13'));
      expect(extractRange('最近三个月', now), (from: '2026-07-01', to: '2026-09-15'));
      expect(extractRange('最近7天', now), (from: '2026-09-09', to: '2026-09-15'));
      expect(extractRange('8月', now), (from: '2026-08-01', to: '2026-08-31'));
      expect(extractRange('今年', now), (from: '2026-01-01', to: '2026-09-15'));
      expect(extractRange('随便', now), isNull);
      expect(previousPeriod((from: '2026-09-01', to: '2026-09-30')), (from: '2026-08-01', to: '2026-08-31'));
      expect(previousPeriod((from: '2026-09-09', to: '2026-09-15')), (from: '2026-09-02', to: '2026-09-08'));
    });
  });

  group('RuleInterpreter on corpus', () {
    test('every corpus case passes in rule mode (regression guard)', () {
      final corpus = Corpus.load('../../corpus/cases.json');
      final rule = RuleInterpreter();
      final metrics = CorpusMetrics();
      final failures = <String>[];
      for (final c in corpus.cases) {
        final s = scoreCase(c, rule.interpretSync(c.text, corpus.context));
        metrics.add(s);
        if (!s.pass) failures.add('${c.id}: ${s.failures.join('; ')}');
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
      expect(metrics.cases, greaterThanOrEqualTo(50));
    });

    test('produces payloads ledger_core accepts as complete', () {
      final corpus = Corpus.load('../../corpus/cases.json');
      final r = RuleInterpreter().interpretSync('昨天晚上打车花了 36 元，微信支付', corpus.context);
      final p = r.drafts.single.payload;
      expect(p['type'], 'expense');
      expect(p['amount_minor'], 3600);
      expect(p['currency'], 'CNY');
      expect(p['account_id'], 'wechat');
      expect(p['category_id'], 'transport');
      expect(p['occurred_at'], '2026-09-14T19:00:00.000+08:00');
      expect(p['description'], '打车');
      expect(r.drafts.single.missing, isEmpty);
      expect(r.drafts.single.confidence, greaterThanOrEqualTo(0.8));
    });

    test('unknown account leaves account_id null with missing flag when no default', () {
      final ctx = InterpretContext(now: DateTime.utc(2026, 9, 15, 4), tzOffsetMinutes: 480, categories: Corpus.load('../../corpus/cases.json').context.categories);
      final r = RuleInterpreter().interpretSync('午饭 28', ctx);
      expect(r.drafts.single.payload['account_id'], isNull);
      expect(r.drafts.single.missing, contains('account_id'));
    });
  });
}
