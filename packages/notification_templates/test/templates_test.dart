import 'package:notification_templates/notification_templates.dart';
import 'package:test/test.dart';

NotificationEvent ev(String pkg, String? title, String text, {String? key}) =>
    NotificationEvent(packageName: pkg, title: title, text: text, postedAtMs: 1789000000000, key: key);

void main() {
  final m = TemplateMatcher();

  test('wechat pay expense with merchant', () {
    final x = m.extract(ev('com.tencent.mm', '微信支付', '已支付¥19.90，商户：瑞幸咖啡', key: '0|com.tencent.mm|1|null|10086'));
    expect(x.usable, isTrue);
    expect(x.direction, 'expense');
    expect(x.amountMinor, 1990);
    expect(x.merchant, '瑞幸咖啡');
    expect(x.accountHint, '微信');
    expect(x.templateId, 'wechat_pay');
    expect(x.fingerprintIsExact, isTrue);
  });

  test('wechat income', () {
    final x = m.extract(ev('com.tencent.mm', '微信收款', '微信支付收款200.00元'));
    expect(x.direction, 'income');
    expect(x.amountMinor, 20000);
    expect(x.fingerprintIsExact, isFalse);
  });

  test('alipay variants', () {
    expect(m.extract(ev('com.eg.android.AlipayGphone', '支付宝', '你有一笔32.50元的消费，商户：美团')).amountMinor, 3250);
    final y = m.extract(ev('com.eg.android.AlipayGphone', '支付宝', '成功付款1,299.00元'));
    expect(y.amountMinor, 129900);
    expect(y.direction, 'expense');
    final z = m.extract(ev('com.eg.android.AlipayGphone', '支付宝', '收到一笔200.00元转账'));
    expect(z.direction, 'income');
    expect(z.amountMinor, 20000);
  });

  test('bank generic with direction group and thousands separator', () {
    final x = m.extract(ev('cmb.pb', '招商银行', '您尾号1234的账户支出1,580.00元，余额12,345.67元'));
    expect(x.templateId, 'bank_generic');
    expect(x.direction, 'expense');
    expect(x.amountMinor, 158000);
    expect(x.accountHint, '招行');
    final y = m.extract(ev('com.icbc', '工商银行', '您的账户收入8,000.00元'));
    expect(y.direction, 'income');
    expect(y.amountMinor, 800000);
  });

  test('marketing / otp ignored; no-amount payment goes to inbox as unusable', () {
    expect(m.extract(ev('com.tencent.mm', '微信支付', '您有一张优惠券即将过期，立即领取')).ignored, isTrue);
    expect(m.extract(ev('com.eg.android.AlipayGphone', '支付宝', '验证码 123456，请勿泄露')).ignored, isTrue);
    final x = m.extract(ev('com.eg.android.AlipayGphone', '支付宝', '你有一笔新的交易，点击查看'));
    expect(x.ignored, isFalse);
    expect(x.usable, isFalse);
    expect(x.accountHint, '支付宝');
  });

  test('generic fallback for unknown apps needs a money verb and currency mark', () {
    final x = m.extract(ev('com.unknown.app', '某App', '支付成功 ¥45.00'));
    expect(x.templateId, 'generic');
    expect(x.amountMinor, 4500);
    expect(m.extract(ev('com.unknown.app', 'x', '你的订单已发货，共 3 件')).usable, isFalse);
  });

  test('user template takes priority and round-trips json', () {
    final t = NotificationTemplate.fromJson({'id': 'my_canteen', 'packages': ['com.school.canteen'], 'text_re': r'消费(?<amount>\d+\.\d\d)元', 'direction': 'expense', 'account_hint': '饭卡', 'confidence': 0.95});
    final mm = TemplateMatcher(userTemplates: [t]);
    final x = mm.extract(ev('com.school.canteen', '食堂', '消费12.50元 余额88.00元'));
    expect(x.templateId, 'my_canteen');
    expect(x.amountMinor, 1250);
    expect(x.accountHint, '饭卡');
    expect(NotificationTemplate.fromJson(t.toJson()).id, 'my_canteen');
  });
}
