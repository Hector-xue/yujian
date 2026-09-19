import 'package:flutter_test/flutter_test.dart';
import 'package:yujian/src/notifications/screenshot_ocr.dart';
import 'package:yujian/src/notifications/screenshot_source.dart';

void main() {
  final shotAt = DateTime(2026, 9, 19, 12, 0);
  List<OcrLine> lines(List<String> ts, {Map<int, int> heights = const {}}) => [for (var i = 0; i < ts.length; i++) OcrLine(ts[i], top: i * 40, height: heights[i] ?? 24)];

  group('screenshot ocr parser', () {
    test('wechat success page: big ¥ amount, merchant under the title, 零钱 → 微信', () {
      final r = ScreenshotOcrParser.parse(lines(['支付成功', '¥36.50', '肯德基（西乡店）', '支付方式', '零钱', '完成'], heights: {1: 90}), fallbackTime: shotAt);
      expect(r.looksLikeTransaction, isTrue);
      expect(r.usable, isTrue);
      expect(r.amountMinor, 3650);
      expect(r.direction, 'expense');
      expect(r.merchant, '肯德基（西乡店）');
      expect(r.accountHint, '微信');
      expect(r.occurredAt, isNull); // 图上没日期
    });

    test('alipay bill detail: labeled amount, merchant label, full date, refund → income', () {
      final r = ScreenshotOcrParser.parse(lines(['账单详情', '退款成功', '收款方 盒马鲜生', '退款金额 ¥18.00', '创建时间 2026-09-18 20:15:33', '支付方式 余额宝']), fallbackTime: shotAt);
      expect(r.usable, isTrue);
      expect(r.amountMinor, 1800);
      expect(r.direction, 'income');
      expect(r.merchant, '盒马鲜生');
      expect(r.accountHint, '支付宝');
      expect(r.occurredAt, DateTime(2026, 9, 18, 20, 15));
    });

    test('order page: 实付 wins over item prices', () {
      final r = ScreenshotOcrParser.parse(lines(['订单详情', '拿铁 ¥28.00', '可颂 ¥16.00', '优惠 -¥5.00', '实付款', '¥39.00', '商家 瑞幸咖啡', '09-19 11:20']), fallbackTime: shotAt);
      expect(r.usable, isTrue);
      expect(r.amountMinor, 3900);
      expect(r.merchant, '瑞幸咖啡');
      expect(r.occurredAt, DateTime(2026, 9, 19, 11, 20));
    });

    test('chat / photo / web screenshots are not transactions (dropped before any model)', () {
      expect(ScreenshotOcrParser.parse(lines(['今晚吃什么', '随便，你定', '那就火锅'])).looksLikeTransaction, isFalse);
      expect(ScreenshotOcrParser.parse(lines(['天气 27°', '晴朗无云', '最高 31° 最低 26°'])).looksLikeTransaction, isFalse);
      expect(ScreenshotOcrParser.parse(const []).looksLikeTransaction, isFalse);
      // 有钱动词但没有像样金额（"支付 三十二元"）：像交易但认不出 → 交给「发文字」档
      final r = ScreenshotOcrParser.parse(lines(['订单详情', '支付 三十二元', '订单号 20260919123456789']));
      expect(r.looksLikeTransaction, isFalse); // 没有 ¥ / 两位小数的金额，连"像交易"都算不上
    });

    test('future dates on the image are distrusted', () {
      final r = ScreenshotOcrParser.parse(lines(['支付成功', '¥9.90', '有效期至 2027-01-01 00:00']), fallbackTime: shotAt);
      expect(r.usable, isTrue);
      expect(r.occurredAt, isNull);
    });
  });
}
