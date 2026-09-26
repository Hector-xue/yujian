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

    test('alipay bill detail: labeled amount, merchant label, full date, refund → refund (not income)', () {
      final r = ScreenshotOcrParser.parse(lines(['账单详情', '退款成功', '收款方 盒马鲜生', '退款金额 ¥18.00', '创建时间 2026-09-18 20:15:33', '支付方式 余额宝']), fallbackTime: shotAt);
      expect(r.usable, isTrue);
      expect(r.amountMinor, 1800);
      expect(r.direction, 'refund'); // 退款冲减原支出，不算收入
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

    test('direction: sign on the chosen amount wins over any word on the page', () {
      // 微信账单详情：支出写 -25.00，页面上却有「退回」「已收款」这种词
      final out = ScreenshotOcrParser.parse(lines(['账单详情', '天福便利店', '-25.00', '当前状态', '支付成功', '支持退回', '商户全称 天福便利店', '支付方式 零钱'], heights: {2: 90}), fallbackTime: shotAt);
      expect(out.direction, 'expense');
      expect(out.amountMinor, 2500);
      final inc = ScreenshotOcrParser.parse(lines(['账单详情', '张三', '+25.00', '当前状态', '已存入零钱', '支付方式 零钱'], heights: {2: 90}), fallbackTime: shotAt);
      expect(inc.direction, 'income');
      expect(inc.amountMinor, 2500);
    });

    test('direction: transfer sent to a friend shows 已收款 / 将退回 but is an expense', () {
      final r = ScreenshotOcrParser.parse(lines(['19:42', '转账给 李四', '¥100.00', '已收款', '转账时间 2026-09-19 11:20:00', '收款时间 2026-09-19 11:21:03', '1天内未收款将退回'], heights: {2: 90}), fallbackTime: shotAt);
      expect(r.usable, isTrue);
      expect(r.direction, 'expense');
      expect(r.amountMinor, 10000);
      expect(r.merchant, '李四');
    });

    test('direction: transfer received shows 已存入零钱 → income', () {
      final r = ScreenshotOcrParser.parse(lines(['来自 李四', '¥100.00', '已存入零钱', '收款时间 2026-09-19 11:21:03'], heights: {1: 90}), fallbackTime: shotAt);
      expect(r.direction, 'income');
      expect(r.amountMinor, 10000);
    });

    test('direction: page with only 收款方 + 支付方式 is an expense (label words are not income)', () {
      final r = ScreenshotOcrParser.parse(lines(['支付宝', '交易成功', '¥18.00', '收款方 盒马鲜生', '支付方式 余额宝', '入账账户 无'], heights: {2: 90}), fallbackTime: shotAt);
      expect(r.direction, 'expense');
      final bank = ScreenshotOcrParser.parse(lines(['交易详情', '收款方 盒马鲜生', '付款金额 18.00元', '付款方式 招商银行储蓄卡', '入账账户 盒马鲜生']), fallbackTime: shotAt);
      expect(bank.direction, 'expense');
      expect(bank.amountMinor, 1800);
    });

    test('direction: headline decides before body words', () {
      final refund = ScreenshotOcrParser.parse(lines(['退款成功', '¥18.00', '收款方 盒马鲜生', '支付方式 余额宝'], heights: {1: 90}), fallbackTime: shotAt);
      expect(refund.direction, 'refund');
      final recv = ScreenshotOcrParser.parse(lines(['收款成功', '¥66.00', '付款方 王五', '备注 饭钱'], heights: {1: 90}), fallbackTime: shotAt);
      expect(recv.direction, 'income');
      final xfer = ScreenshotOcrParser.parse(lines(['转账成功', '¥500.00', '转入 招商银行 尾号1234'], heights: {1: 90}), fallbackTime: shotAt);
      expect(xfer.direction, 'transfer');
    });

    test('amount label: 优惠金额 is not the paid amount', () {
      final r = ScreenshotOcrParser.parse(lines(['订单详情', '商品金额 ¥45.00', '优惠金额 -¥5.00', '实付金额 ¥40.00', '商家 瑞幸咖啡']), fallbackTime: shotAt);
      expect(r.amountMinor, 4000);
      expect(r.direction, 'expense');
    });

    test('future dates on the image are distrusted', () {
      final r = ScreenshotOcrParser.parse(lines(['支付成功', '¥9.90', '有效期至 2027-01-01 00:00']), fallbackTime: shotAt);
      expect(r.usable, isTrue);
      expect(r.occurredAt, isNull);
    });

    test('bill list screenshot: one draft per signed amount, time below each amount', () {
      final wx = ScreenshotOcrParser.parseList(lines(['14:02', '账单', '9月', '扫二维码付款-给张三', '-25.00', '9月19日 11:20', '瑞幸咖啡', '-19.90', '9月18日 08:10', '淘宝-退款', '+45.00', '9月17日 20:00']), fallbackTime: shotAt);
      expect(wx.map((x) => (x.direction, x.amountMinor, x.merchant)).toList(), [('expense', 2500, '扫二维码付款-给张三'), ('expense', 1990, '瑞幸咖啡'), ('refund', 4500, '淘宝-退款')]);
      expect(wx[1].occurredAt, DateTime(2026, 9, 18, 8, 10));
      // 单笔详情页不是列表
      expect(ScreenshotOcrParser.parseList(lines(['支付成功', '-25.00', '天福便利店', '-3.00']), fallbackTime: shotAt), isEmpty);
      expect(ScreenshotOcrParser.parseList(lines(['天福便利店', '-25.00']), fallbackTime: shotAt), isEmpty);
    });
  });
}
