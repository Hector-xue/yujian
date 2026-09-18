import 'package:notification_templates/notification_templates.dart';
import 'package:test/test.dart';

NotificationEvent ev(String pkg, String text) => NotificationEvent(packageName: pkg, title: null, text: text, postedAtMs: 1789000000000);

void main() {
  test('candidates: money-like numbers, long ints skipped', () {
    final c = TemplateLearner.candidates('尾号6688 消费 ¥36.50，订单 202609181234');
    expect(c.map((x) => x.text), ['6688', '36.50']);
    expect(c.firstWhere((x) => x.text == '36.50').likely, isTrue);
    expect(c.firstWhere((x) => x.text == '6688').likely, isFalse);
  });

  test('learn: prefix anchor + merchant after amount, then matches via TemplateMatcher', () {
    const text = '您尾号8888的卡消费36.50元，商户：肯德基';
    final c = TemplateLearner.candidates(text).firstWhere((x) => x.text == '36.50');
    final t = TemplateLearner.learn(id: 'my_bank', packageName: 'com.example.bank', text: text, amount: c, direction: 'expense', merchant: '肯德基', accountHint: '某行');
    expect(t, isNotNull);
    final m = TemplateMatcher(userTemplates: [NotificationTemplate.fromJson(t!)]);
    final x = m.extract(ev('com.example.bank', text));
    expect(x.templateId, 'my_bank');
    expect(x.amountMinor, 3650);
    expect(x.merchant, '肯德基');
    expect(x.accountHint, '某行');
    // 换个金额、换个商户照样认
    final y = m.extract(ev('com.example.bank', '您尾号8888的卡消费1,299.00元，商户：京东'));
    expect(y.amountMinor, 129900);
    expect(y.merchant, '京东');
    // 别的包不认
    expect(m.extract(ev('com.other', text)).templateId, isNot('my_bank'));
  });

  test('learn: amount at the very start uses suffix anchor', () {
    const text = '36.50元 已从余额扣除';
    final c = TemplateLearner.candidates(text).first;
    final t = TemplateLearner.learn(id: 't', packageName: null, text: text, amount: c, direction: 'expense');
    expect(t, isNotNull);
    expect(RegExp(t!['text_re'] as String).firstMatch('12.00元 已从余额扣除')?.namedGroup('amount'), '12.00');
  });

  test('learn: merchant before amount', () {
    const text = '肯德基 向你收款 ¥36.50';
    final c = TemplateLearner.candidates(text).firstWhere((x) => x.text == '36.50');
    final t = TemplateLearner.learn(id: 't', packageName: 'p', text: text, amount: c, direction: 'expense', merchant: '肯德基');
    final m = RegExp(t!['text_re'] as String).firstMatch('麦当劳 向你收款 ¥9.90');
    expect(m?.namedGroup('amount'), '9.90');
    expect(m?.namedGroup('merchant'), '麦当劳');
  });

  test('learn: anchor does not swallow previous number', () {
    const text = '尾号1234 支付 88.00';
    final c = TemplateLearner.candidates(text).firstWhere((x) => x.text == '88.00');
    final t = TemplateLearner.learn(id: 't', packageName: 'p', text: text, amount: c, direction: 'expense');
    expect(RegExp(t!['text_re'] as String).firstMatch('尾号9999 支付 5.00')?.namedGroup('amount'), '5.00');
  });

  test('learn: nothing to anchor on returns null', () {
    const text = '36.50';
    final c = TemplateLearner.candidates(text).first;
    expect(TemplateLearner.learn(id: 't', packageName: 'p', text: text, amount: c, direction: 'expense'), isNull);
  });
}
