import 'package:ledger_core/ledger_core.dart';

import 'event.dart';

/// 一条模板：匹配包名 + 文案正则，命名分组 amount / merchant；direction 固定或按关键词判。
///
/// [titleRe] 只匹配通知标题；微信把多条未读合成一条时标题是「微信」、正文以「微信支付: …」开头，这种用 [textPrefixRe]
/// 认正文开头（允许「[2条]」前缀）。以前 titleRe 也去整段正文里找，朋友消息里提一句「微信支付」就会被当成支付通知。
class NotificationTemplate {
  final String id;
  final Set<String> packages; // 空 = 任意包
  final RegExp? titleRe;
  final RegExp? textPrefixRe;
  final RegExp textRe;
  final String? direction; // 固定方向；null 则按关键词
  final String? accountHint;
  final double confidence;
  final bool builtin;

  const NotificationTemplate({
    required this.id,
    this.packages = const {},
    this.titleRe,
    this.textPrefixRe,
    required this.textRe,
    this.direction,
    this.accountHint,
    this.confidence = 0.8,
    this.builtin = true,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'packages': packages.toList(),
        'title_re': titleRe?.pattern,
        'text_re': textRe.pattern,
        'direction': direction,
        'account_hint': accountHint,
        'confidence': confidence,
      };

  factory NotificationTemplate.fromJson(Map<String, Object?> j) => NotificationTemplate(
        id: j['id'] as String,
        packages: ((j['packages'] as List?) ?? const []).cast<String>().toSet(),
        titleRe: j['title_re'] == null ? null : RegExp(j['title_re'] as String),
        textRe: RegExp(j['text_re'] as String),
        direction: j['direction'] as String?,
        accountHint: j['account_hint'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.8,
        builtin: false,
      );
}

/// 包名 → 账户线索。
const packageAccountHints = <String, String>{
  'com.tencent.mm': '微信',
  'com.eg.android.AlipayGphone': '支付宝',
  'com.unionpay': '云闪付',
  'cmb.pb': '招行',
  'com.icbc': '工行',
  'com.chinamworld.main': '建行',
  'com.android.bankabc': '农行',
  'com.chinamworld.bocmbci': '中行',
  'com.bankcomm.Bankcomm': '交行',
  'com.yitong.mbank.psbc': '邮储',
  'com.cmbchina.ccd.pluto.cmbActivity': '招行信用卡',
  'com.jd.jrapp': '京东',
};

/// 购物 / 出行 / 外卖平台：它们的通知是「支付成功 ¥xx」，钱其实从微信 / 支付宝 / 银行卡走，
/// 所以不给账户线索（落到默认账户，收件箱里改），只认方向和金额。
const shoppingPackages = <String, String>{
  'com.taobao.taobao': '淘宝',
  'com.tmall.wireless': '天猫',
  'com.jingdong.app.mall': '京东',
  'com.xunmeng.pinduoduo': '拼多多',
  'com.sankuai.meituan': '美团',
  'com.sankuai.meituan.takeoutnew': '美团外卖',
  'me.ele': '饿了么',
  'com.ss.android.ugc.aweme': '抖音',
  'com.xingin.xhs': '小红书',
  'com.sdu.didi.psnger': '滴滴',
  'com.MobileTicket': '12306',
  'ctrip.android.view': '携程',
  'com.dianping.v1': '大众点评',
  'com.achievo.vipshop': '唯品会',
  'com.suning.mobile.ebuy': '苏宁',
  'com.wudaokou.hippo': '盒马',
  'com.dmall.dmall': '多点',
  'com.unionpay': '云闪付',
};

/// 聊天软件：通知大多是人发的消息，「我付了 200 元」不是账。泛用兜底模板对这些包要求正文里有 ¥ 符号（服务号 / 商家通知几乎都带）。
const imPackages = <String>{
  'com.tencent.mm',
  'com.tencent.mobileqq',
  'com.tencent.wework',
  'com.alibaba.android.rimet',
  'com.ss.android.lark',
  'org.telegram.messenger',
  'com.whatsapp',
};

/// 微信官方服务号的名字：合并通知里正文以它开头才算支付通知。
final _wechatServiceRe = RegExp(r'^(?:\[\d+条\])?\s*(?:微信支付|微信收款助手|微信支付分|微信收款商业版)\s*[:：]');

/// 与交易无关的通知：验证码、营销、红包提醒等。
final _ignoreRe = RegExp('验证码|优惠券|领取|活动|推荐|会员日|红包待领|积分|广告|通知权限|账单日|还款提醒|待还|限时|立减|已发货|已签收|派送中|运输中|待评价|物流|快递|包裹|好评|开始配送|骑手|已接单|预计送达|订单已完成');

final _amountRe = RegExp(r'(?:¥|￥|RMB|CNY|人民币)?\s*(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*(?:元|¥|￥)?');
final _expenseRe = RegExp('支付成功|已支付|付款成功|扣款|消费|支出|已付|支付了|付款|已扣|实付|成功购买|下单成功|购买成功');
final _incomeRe = RegExp('收款|到账|入账|收入|已收|转入|退款到|退回');
final _transferRe = RegExp('转账成功|已转出|转出|提现');

/// 内置模板。顺序 = 优先级；泛用模板最后。
final builtinTemplates = <NotificationTemplate>[
  // 微信支付：常见文案 "已支付¥19.90" / "微信支付收款19.90元" / "你已成功支付19.90元"
  NotificationTemplate(
    id: 'wechat_pay',
    packages: {'com.tencent.mm'},
    titleRe: RegExp('微信支付|微信收款|收款到账'),
    textPrefixRe: _wechatServiceRe,
    textRe: RegExp(r'(?:已支付|支付成功|成功支付|付款)\s*[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?(?:[，,\s]*(?:商户|向|付款给|给)[:：]?\s*(?<merchant>[^，,。\s]{1,20}))?'),
    direction: 'expense',
    accountHint: '微信',
    confidence: 0.9,
  ),
  NotificationTemplate(
    id: 'wechat_income',
    packages: {'com.tencent.mm'},
    titleRe: RegExp('微信支付|微信收款|收款到账|转账'),
    textPrefixRe: _wechatServiceRe,
    textRe: RegExp(r'(?:收款|到账|转账)\s*[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?'),
    direction: 'income',
    accountHint: '微信',
    confidence: 0.85,
  ),
  // 支付宝："你有一笔19.90元的消费" / "成功付款19.90元" / "收到一笔200.00元转账"
  NotificationTemplate(
    id: 'alipay_pay',
    packages: {'com.eg.android.AlipayGphone'},
    textRe: RegExp(r'(?:付款|支付|消费|扣款)[^\d¥￥]{0,12}[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?(?:[，,\s]*(?:商户|向|在)[:：]?\s*(?<merchant>[^，,。\s]{1,20}))?|(?:你有一笔|一笔)\s*[¥￥]?\s*(?<amount2>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?\s*的?(?:消费|支出|付款)'),
    direction: 'expense',
    accountHint: '支付宝',
    confidence: 0.9,
  ),
  NotificationTemplate(
    id: 'alipay_income',
    packages: {'com.eg.android.AlipayGphone'},
    textRe: RegExp(r'(?:收到|到账|收款|入账)[^\d¥￥]{0,12}[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?'),
    direction: 'income',
    accountHint: '支付宝',
    confidence: 0.85,
  ),
  // 购物 / 外卖 / 出行平台："支付成功 ¥86.00" / "您已成功支付86元" / "订单支付成功，实付¥86.00"
  NotificationTemplate(
    id: 'shop_pay',
    packages: shoppingPackages.keys.toSet(),
    textRe: RegExp(r'(?:支付成功|付款成功|已支付|成功支付|实付|支付了|已付款|购买成功|下单成功)[^\d¥￥]{0,14}[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?(?:[，,\s]*(?:商户|商家|店铺|向|在)[:：]?\s*(?<merchant>[^，,。\s]{1,20}))?|[¥￥]\s*(?<amount2>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)[^。]{0,10}(?:支付成功|付款成功|已支付)'),
    direction: 'expense',
    confidence: 0.75,
  ),
  NotificationTemplate(
    id: 'shop_refund',
    packages: shoppingPackages.keys.toSet(),
    textRe: RegExp(r'(?:退款|退回|退还)[^\d¥￥]{0,14}[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?'),
    direction: 'income',
    confidence: 0.7,
  ),
  // 银行 App：文案里通常有"支出/收入 + 金额 + 余额"
  NotificationTemplate(
    id: 'bank_generic',
    packages: {},
    titleRe: RegExp('银行|信用卡|借记卡|储蓄卡|云闪付'),
    textRe: RegExp(r'(?<dir>支出|消费|收入|入账|转入|转出)[^\d]{0,12}(?<amount>\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元'),
    confidence: 0.75,
  ),
  // 泛用兜底：任何包，只要有钱动词 + 金额
  NotificationTemplate(
    id: 'generic',
    packages: {},
    textRe: RegExp(r'.'),
    confidence: 0.5,
  ),
];

class TemplateMatcher {
  final List<NotificationTemplate> templates;
  TemplateMatcher({List<NotificationTemplate> userTemplates = const []}) : templates = [...userTemplates, ...builtinTemplates];

  /// App 名本身含"支付"等钱动词（支付宝、微信支付），判方向前先剥掉。
  static final _appNameRe = RegExp('支付宝|微信支付|微信收款|云闪付|微信');

  Extraction extract(NotificationEvent e) {
    final text = _appNameRe.allMatches('${e.title ?? ''} ${e.text}').isEmpty
        ? '${e.title ?? ''} ${e.text}'.trim()
        : '${e.title ?? ''} ${e.text}'.replaceAll(_appNameRe, ' ').trim();
    final fp = _fingerprint(e);
    if (_ignoreRe.hasMatch(text) && !_expenseRe.hasMatch(text) && !_incomeRe.hasMatch(text)) {
      return Extraction(templateId: 'ignore', ignored: true, confidence: 1, fingerprint: fp.$1, fingerprintIsExact: fp.$2);
    }
    for (final t in templates) {
      if (t.packages.isNotEmpty && !t.packages.contains(e.packageName)) continue;
      if (t.titleRe != null && !(t.titleRe!.hasMatch(e.title ?? '') || (t.textPrefixRe?.hasMatch(e.text) ?? false))) continue;
      final m = t.textRe.firstMatch(e.text);
      if (m == null) continue;
      if (t.id == 'generic') {
        final g = _generic(e, text, fp);
        if (g != null) return g;
        continue;
      }
      String? group(String name) {
        try {
          return m.namedGroup(name);
        } catch (_) {
          return null;
        }
      }
      final amtText = group('amount') ?? group('amount2');
      if (amtText == null) continue;
      final amount = _minor(amtText);
      if (amount == null) continue;
      var dir = t.direction;
      if (dir == null) {
        final d = group('dir') ?? '';
        dir = RegExp('支出|消费|转出').hasMatch(d) ? 'expense' : (RegExp('收入|入账|转入').hasMatch(d) ? 'income' : _directionOf(text));
      }
      return Extraction(
        templateId: t.id,
        direction: dir,
        amountMinor: amount,
        merchant: group('merchant') ?? _merchantOf(e.text),
        accountHint: t.accountHint ?? packageAccountHints[e.packageName],
        confidence: t.confidence,
        fingerprint: fp.$1,
        fingerprintIsExact: fp.$2,
      );
    }
    return Extraction(templateId: 'none', confidence: 0, fingerprint: fp.$1, fingerprintIsExact: fp.$2, accountHint: packageAccountHints[e.packageName]);
  }

  Extraction? _generic(NotificationEvent e, String text, (String, bool) fp) {
    final dir = _directionOf(text);
    if (dir == null) return null;
    // 聊天软件里的人话（「我付了 200 元」）不是账：兜底模板只认带 ¥ 的
    if (imPackages.contains(e.packageName) && !RegExp(r'[¥￥]').hasMatch(e.text)) return null;
    final m = _amountRe.allMatches(text).where((x) => RegExp(r'[¥￥元]').hasMatch(text.substring(x.start, (x.end + 1).clamp(0, text.length))) || RegExp(r'[¥￥]').hasMatch(x.group(0)!)).firstOrNull;
    if (m == null) return null;
    final amount = _minor(m.group(1)!);
    if (amount == null) return null;
    return Extraction(
      templateId: 'generic',
      direction: dir,
      amountMinor: amount,
      merchant: _merchantOf(e.text),
      accountHint: packageAccountHints[e.packageName],
      confidence: 0.5,
      fingerprint: fp.$1,
      fingerprintIsExact: fp.$2,
    );
  }

  /// 按关键词判方向（学模板时也用它预选）。
  static String? directionOf(String text) => _directionOf(text);

  static String? _directionOf(String text) {
    if (_transferRe.hasMatch(text)) return 'transfer';
    if (_incomeRe.hasMatch(text) && !_expenseRe.hasMatch(text)) return 'income';
    if (_expenseRe.hasMatch(text)) return 'expense';
    if (_incomeRe.hasMatch(text)) return 'income';
    return null;
  }

  static String? _merchantOf(String text) {
    final m = RegExp(r'(?:商户|商家|收款方|付款给|向|在)[:：]?\s*([^，,。\s¥￥\d]{2,20})').firstMatch(text);
    if (m != null) return m.group(1);
    final dash = RegExp(r'^([^\-—:：]{2,20})\s*[-—:：]').firstMatch(text);
    return dash?.group(1)?.trim();
  }

  static int? _minor(String s) {
    try {
      return Money.parse(s.replaceAll(',', ''), 'CNY').minor;
    } catch (_) {
      return null;
    }
  }

  /// 有系统 key：key + 标题正文的稳定哈希 = 精确指纹。只挡「同一条通知被系统重发 / 更新但内容没变」；
  /// 不能只用 key——安卓的 key 是「包名 + 通知 id + tag」，微信这类 App 同一个会话一直复用同一个 id，
  /// 只用 key 的话第二笔支付会被当成第一笔的重复静默丢掉。
  /// 没有 key：包名 + 分钟桶 + 文案哈希，只能算候选。
  static (String, bool) _fingerprint(NotificationEvent e) {
    final h = stableHash('${e.title ?? ''}\n${e.text}');
    if (e.key != null && e.key!.isNotEmpty) return ('notif:${e.packageName}:${e.key}:$h', true);
    final minute = e.postedAtMs ~/ 60000;
    return ('notif:${e.packageName}:$minute:$h', false);
  }

  /// 跨运行、跨平台稳定的哈希（String.hashCode 不保证稳定，指纹要落库比对）。两路 31 位多项式，
  /// 全程 < 2^53，Web(JS 数字) 与原生结果一致。
  static String stableHash(String s) {
    var a = 7;
    var b = 13;
    for (final c in s.codeUnits) {
      a = (a * 131 + c) % 2147483647;
      b = (b * 137 + c) % 2147483629;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}${b.toRadixString(16).padLeft(8, '0')}';
  }
}
