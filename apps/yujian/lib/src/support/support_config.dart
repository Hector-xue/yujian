/// 「支持余见」的收款配置。两个二维码的内容（不是图片）：
/// 支付宝个人收款码扫出来是 `https://qr.alipay.com/…`，微信个人收款码是 `wxp://f2f0…`；App 里用它们现画二维码，
/// 支付宝还能拿这个 URL 直接拉起付款页。为空 = 那条付款路不显示（配置没填全时页面只留「我已支持」）。
class SupportConfig {
  SupportConfig._();

  /// 支付宝收款码内容。
  static const alipayQr = String.fromEnvironment('YUJIAN_SUPPORT_ALIPAY', defaultValue: _alipayQr);

  /// 微信收款码内容。
  static const wechatQr = String.fromEnvironment('YUJIAN_SUPPORT_WECHAT', defaultValue: _wechatQr);

  /// 金额（分）。自动识别只认这个数。
  static const amountMinor = 100;

  /// 点了付款按钮后多久之内识别到这个金额的支付，算作支持余见。
  static const detectWindow = Duration(minutes: 10);

  /// 提醒出现的门槛：记满这么多笔，或用满这么多天（两者取先到）。先让人尝到甜头再提。
  static const minTransactions = 30;
  static const minDays = 14;

  /// 「30 天后再说」。
  static const snoozeDays = 30;

  static bool get hasAlipay => alipayQr.isNotEmpty;
  static bool get hasWechat => wechatQr.isNotEmpty;
  static bool get configured => hasAlipay || hasWechat;

  /// 拉起支付宝到这个收款码的付款页（个人收款码可用；没装支付宝会失败，调用方回退到展示二维码）。
  static Uri get alipayLaunchUri => Uri.parse('alipays://platformapi/startapp?saId=10000007&qrcode=${Uri.encodeComponent(alipayQr)}');

  /// 拉起微信扫一扫（微信没有个人收款码的直达协议，只能先把码存进相册再扫）。
  static Uri get wechatScanUri => Uri.parse('weixin://scanqrcode');

  // 收款码内容在这里（发版前填；也可在构建时用 --dart-define 覆盖）。
  static const _alipayQr = '';
  static const _wechatQr = 'wxp://f2f03Pb3FgIFbhpbb-FXdFJGRW9QaZ2wZVDfmkTwZLyPnhQ';
}
