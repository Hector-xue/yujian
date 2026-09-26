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

  test('same notification key reused by the app: different payments are not duplicates', () {
    const key = '0|com.tencent.mm|1234|null|10123';
    final a = m.extract(ev('com.tencent.mm', '微信支付', '已支付¥19.90', key: key));
    final b = m.extract(ev('com.tencent.mm', '微信支付', '已支付¥36.00', key: key));
    final again = m.extract(ev('com.tencent.mm', '微信支付', '已支付¥19.90', key: key));
    expect(a.fingerprintIsExact, isTrue);
    expect(a.fingerprint, isNot(b.fingerprint)); // 第二笔不能被当重复吞掉
    expect(a.fingerprint, again.fingerprint); // 同一条被系统重发 / 更新：仍是重复
  });

  test('stable hash is deterministic', () {
    expect(TemplateMatcher.stableHash('已支付¥19.90'), TemplateMatcher.stableHash('已支付¥19.90'));
    expect(TemplateMatcher.stableHash('a'), isNot(TemplateMatcher.stableHash('b')));
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

  test('shopping platforms: pay / refund / logistics noise', () {
    final jd = m.extract(ev('com.jingdong.app.mall', '京东', '订单支付成功，实付¥86.00，商家：京东自营'));
    expect(jd.templateId, 'shop_pay');
    expect(jd.direction, 'expense');
    expect(jd.amountMinor, 8600);
    expect(jd.merchant, '京东自营');
    expect(jd.accountHint, isNull, reason: '钱从哪个渠道走不知道，别硬猜账户');
    final tb = m.extract(ev('com.taobao.taobao', '淘宝', '您已成功支付129元，卖家将尽快发货'));
    expect(tb.amountMinor, 12900);
    expect(tb.direction, 'expense');
    final mt = m.extract(ev('com.sankuai.meituan.takeoutnew', '美团外卖', '¥23.50 支付成功，商家已接单'));
    expect(mt.amountMinor, 2350);
    expect(mt.templateId, 'shop_pay');
    final rf = m.extract(ev('com.xunmeng.pinduoduo', '拼多多', '退款成功，¥45.00 已退回原支付账户'));
    expect(rf.direction, 'refund'); // 退款冲减支出，不算收入
    expect(rf.amountMinor, 4500);
    expect(m.extract(ev('com.jingdong.app.mall', '京东', '您的包裹已签收，快递员：张三')).ignored, isTrue);
    expect(m.extract(ev('com.sankuai.meituan.takeoutnew', '美团外卖', '骑手已接单，预计送达 12:30')).ignored, isTrue);
  });

  test('screen-recognized payment (accessibility) matches the same templates', () {
    final w = m.extract(ev('com.tencent.mm', '微信支付 支付成功页', '支付成功 ¥13.80 商户：杨国福麻辣烫', key: 'screen:com.tencent.mm:13.80:29816700'));
    expect(w.templateId, 'wechat_pay');
    expect(w.amountMinor, 1380);
    expect(w.merchant, '杨国福麻辣烫');
    expect(w.accountHint, '微信');
    expect(w.fingerprintIsExact, isTrue);
    final a = m.extract(ev('com.eg.android.AlipayGphone', '支付宝 支付成功页', '支付成功 ¥9.00 商户：肉夹馍'));
    expect(a.templateId, 'alipay_pay');
    expect(a.amountMinor, 900);
    expect(a.merchant, '肉夹馍');
    final j = m.extract(ev('com.jingdong.app.mall', '京东 支付成功页', '支付成功 ¥199.00'));
    expect(j.templateId, 'shop_pay');
    expect(j.amountMinor, 19900);
  });

  test('chat messages on IM apps are not transactions', () {
    // 朋友消息（标题=人名）：正文里提到「微信支付」「已支付」也不是支付通知
    final a = m.extract(ev('com.tencent.mm', '张三', '微信支付已支付¥20，你看一下'));
    expect(a.templateId, isNot('wechat_pay'));
    // 兜底模板：聊天软件里没有 ¥ 的人话不起草
    final b = m.extract(ev('com.tencent.mm', '张三', '我已支付 200 元，你记一下'));
    expect(b.usable, isFalse);
    final c = m.extract(ev('com.tencent.mm', '李四', '转账 100 元给你了'));
    expect(c.usable, isFalse);
    // 合并通知：标题「微信」、正文以服务号名开头 → 仍认
    final d = m.extract(ev('com.tencent.mm', '微信', '[2条]微信支付: 已支付¥19.90，商户：瑞幸咖啡'));
    expect(d.templateId, 'wechat_pay');
    expect(d.amountMinor, 1990);
    // 短信 / 银行 App 不受影响：没有 ¥ 也走兜底
    final e = m.extract(ev('com.android.mms', '95555', '您尾号1234的账户消费58.00元'));
    expect(e.usable, isTrue);
    expect(e.direction, 'expense');
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
