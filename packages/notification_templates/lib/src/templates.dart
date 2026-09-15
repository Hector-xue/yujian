import 'package:ledger_core/ledger_core.dart';

import 'event.dart';

/// 一条模板：匹配包名 + 文案正则，命名分组 amount / merchant；direction 固定或按关键词判。
class NotificationTemplate {
  final String id;
  final Set<String> packages; // 空 = 任意包
  final RegExp? titleRe;
  final RegExp textRe;
  final String? direction; // 固定方向；null 则按关键词
  final String? accountHint;
  final double confidence;
  final bool builtin;

  const NotificationTemplate({
    required this.id,
    this.packages = const {},
    this.titleRe,
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
  'com.sankuai.meituan': '美团',
};

/// 与交易无关的通知：验证码、营销、红包提醒等。
final _ignoreRe = RegExp('验证码|优惠券|领取|活动|推荐|会员日|红包待领|积分|广告|通知权限|账单日|还款提醒|待还|限时|立减');

final _amountRe = RegExp(r'(?:¥|￥|RMB|CNY|人民币)?\s*(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*(?:元|¥|￥)?');
final _expenseRe = RegExp('支付成功|已支付|付款成功|扣款|消费|支出|已付|支付了|付款|已扣');
final _incomeRe = RegExp('收款|到账|入账|收入|已收|转入|退款到|退回');
final _transferRe = RegExp('转账成功|已转出|转出|提现');

/// 内置模板。顺序 = 优先级；泛用模板最后。
final builtinTemplates = <NotificationTemplate>[
  // 微信支付：常见文案 "已支付¥19.90" / "微信支付收款19.90元" / "你已成功支付19.90元"
  NotificationTemplate(
    id: 'wechat_pay',
    packages: {'com.tencent.mm'},
    titleRe: RegExp('微信支付|微信收款|收款到账'),
    textRe: RegExp(r'(?:已支付|支付成功|成功支付|付款)\s*[¥￥]?\s*(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?(?:[，,\s]*(?:商户|向|付款给|给)[:：]?\s*(?<merchant>[^，,。\s]{1,20}))?'),
    direction: 'expense',
    accountHint: '微信',
    confidence: 0.9,
  ),
  NotificationTemplate(
    id: 'wechat_income',
    packages: {'com.tencent.mm'},
    titleRe: RegExp('微信支付|微信收款|收款到账|转账'),
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
      if (t.titleRe != null && !(t.titleRe!.hasMatch(e.title ?? '') || t.titleRe!.hasMatch(e.text))) continue;
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

  /// 有系统 key 就是精确指纹；否则 包名+分钟桶+金额 只能算候选。
  static (String, bool) _fingerprint(NotificationEvent e) {
    if (e.key != null && e.key!.isNotEmpty) return ('notif:${e.packageName}:${e.key}', true);
    final minute = e.postedAtMs ~/ 60000;
    return ('notif:${e.packageName}:$minute:${e.text.hashCode}', false);
  }
}
