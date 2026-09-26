import 'package:ledger_core/ledger_core.dart';
import 'package:notification_templates/notification_templates.dart';

import 'screenshot_source.dart';

/// 本机 OCR 文字 → 一笔交易的要素。纯 Dart、不出网，截图自动记账「仅本地」档的解析器。
///
/// 截图比通知杂：支付成功页、账单详情、订单页、小票都可能。思路：
/// 1. 先判「像不像一笔交易」：要有金额（¥ / 元 / 两位小数）+ 钱动词（支付 / 付款 / 消费 / 收款 / 退款 / 实付 / 合计 …），
///    聊天、照片、网页这种在这一步就丢掉，连「认不出时发文字」那一档也不会碰到它；
/// 2. 金额：优先「实付 / 合计 / 支付金额」这类标签旁边的；没有就取带 ¥ 且字最大的那行（支付成功页的大字金额）；
/// 3. 方向：分级取证，命中就停——选中金额自带的正负号 → 页面标题 / 状态行（支付成功 / 退款成功 / 转账成功）
///    → 金额所在标签（退款金额 / 实付）→ 对方标识（转账给 / 来自）→ 受限关键词兜底。整页里「已收款」「退回」「入账」这类词
///    多半是标签或说明（转账给别人的页面也写「已收款」，付款页脚注「将退回」），不能见词就判收入；
/// 4. 商户：「收款方 / 商户 / 店铺 / 付款给 / 商品」标签后面的；微信成功页则是「支付成功」下一行；
/// 5. 时间：文字里有完整日期就用（账单详情页都有），没有就用截图时间；
/// 6. 账户线索：微信 / 零钱 / 支付宝 / 余额宝 / 银行名。
class LocalShot {
  final int? amountMinor;
  final String? direction;
  final String? merchant;
  final String? accountHint;
  final DateTime? occurredAt; // 本地时间
  final double confidence;
  /// 图上有没有「像交易」的痕迹（没有 = 聊天 / 照片 / 网页，直接忽略）。
  final bool looksLikeTransaction;
  final String text; // 拼起来的全文（发文字档用；发之前再脱敏）
  const LocalShot({this.amountMinor, this.direction, this.merchant, this.accountHint, this.occurredAt, this.confidence = 0, required this.looksLikeTransaction, required this.text});

  bool get usable => looksLikeTransaction && amountMinor != null && amountMinor! > 0 && direction != null;

  /// 证据够硬（标签旁的金额、或带 ¥ 的大字）：「发文字」档到这里就不再问模型。
  bool get confident => usable && confidence >= 0.6;
}

class ScreenshotOcrParser {
  static final _amountRe = RegExp(r'(?:[¥￥]|RMB|CNY)?\s*[-−+]?\s*(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*(?:元|CNY|RMB)?');
  static final _strongAmountRe = RegExp(r'(?:[¥￥]\s*[-−+]?\s*(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?))|(?:[-−+]?\s*(\d{1,3}(?:,\d{3})+\.\d{2}|\d+\.\d{2})\s*元?(?!\d))');
  static final _moneyWordRe = RegExp('支付|付款|消费|收款|收入|到账|退款|转账|实付|合计|总计|应付|订单|账单|交易|金额|扣款|入账|转入|转出|花呗|零钱|余额');
  // 标签分两档：明确的先找；「xx金额」这种泛标签后找，且不要「优惠金额 / 抵扣金额 / 余额」
  static final _amountLabelRe = RegExp('实付款?|实际支付|付款金额|支付金额|交易金额|合计|总计|应付|订单金额|退款金额|到账金额|收款金额');
  static final _amountLabelLooseRe = RegExp('金额');
  static final _notAmountLabelRe = RegExp('优惠|折扣|抵扣|立减|减免|余额|返现|积分');
  static final _incomeLabelRe = RegExp('到账金额|收款金额');
  static final _refundRe = RegExp('退款成功|已退款|退款金额|退款到账|退款详情');
  static final _expenseLabelRe = RegExp('实付|实际支付|付款金额|支付金额');
  static final _merchantLabelRe = RegExp(r'^(收款方全称|收款方|收款商户|收款人|商户全称|商户名称|商户|商家|店铺|付款给|向|付款商户|商品说明|商品|交易对方|对方|转账给|收款账户)[:：]?\s*(.*)$');
  // 方向证据（按优先级）
  static final _signExpenseRe = RegExp(r'^\s*(?:[-−]\s*[¥￥]?|[¥￥]\s*[-−])\s*\d');
  static final _signIncomeRe = RegExp(r'^\s*(?:\+\s*[¥￥]?|[¥￥]\s*\+)\s*\d');
  static final _headExpenseRe = RegExp('支付成功|付款成功|交易成功|支付完成|付款完成|消费成功|扣款成功');
  static final _headIncomeRe = RegExp('收款成功|收款到账|已到账|到账成功|退款成功|已退款|已存入|入账成功|收款通知');
  static final _headTransferRe = RegExp('转账成功|提现成功|转出成功');
  static final _partyExpenseRe = RegExp('转账给|付款给|收款方|收款人|商户全称|商户名称');
  static final _partyIncomeRe = RegExp('来自|付款方|向你转账|给你转账|收到.{0,6}转账');
  static final _wordIncomeRe = RegExp('退款成功|已退款|收款成功|收款到账|已到账|到账成功|已存入零钱');
  static final _wordExpenseRe = RegExp('支付成功|已支付|付款成功|扣款|消费|支出|已付|支付了|付款|实付');
  static final _statusBarRe = RegExp(r'^\d{1,2}:\d{2}|KB/s|MB/s|^\d{1,3}%?$');
  static final _successRe = RegExp('支付成功|付款成功|交易成功|支付完成|付款完成|转账成功|退款成功|已支付|已付款');
  static final _noiseRe = RegExp('支付成功|付款成功|交易成功|支付完成|完成|返回|关闭|查看|账单|详情|再付一笔|去看看|领取|红包|奖励|优惠|会员|积分|分享|立即|开通|余额|零钱|银行卡|花呗|信用卡|扣款|付款方式|支付方式|订单|时间|备注|实付|付款|金额|合计|应付|抵扣|¥|￥|^\\d');
  static final _dateRe = RegExp(r'(20\d{2})[-/.年]\s*(\d{1,2})[-/.月]\s*(\d{1,2})日?\s*(?:[ T]?(\d{1,2})[:：](\d{2})(?:[:：](\d{2}))?)?');
  static final _shortDateRe = RegExp(r'(?<![\d.])(\d{1,2})[-/月](\d{1,2})日?\s+(\d{1,2})[:：](\d{2})');
  static final _accountHints = <RegExp, String>{
    RegExp('零钱通|零钱|微信支付|微信'): '微信',
    RegExp('余额宝|花呗|支付宝'): '支付宝',
    RegExp('云闪付'): '云闪付',
    RegExp('招商银行|招行'): '招商银行',
    RegExp('工商银行|工行'): '工商银行',
    RegExp('建设银行|建行'): '建设银行',
    RegExp('农业银行|农行'): '农业银行',
    RegExp('中国银行'): '中国银行',
    RegExp('交通银行'): '交通银行',
    RegExp('邮储|邮政储蓄'): '邮储银行',
    RegExp('平安银行'): '平安银行',
    RegExp('浦发'): '浦发银行',
    RegExp('民生银行'): '民生银行',
    RegExp('兴业银行'): '兴业银行',
    RegExp('光大银行'): '光大银行',
    RegExp('中信银行'): '中信银行',
  };

  static int? _minor(String s) {
    try {
      return Money.parse(s.replaceAll(',', ''), 'CNY').minor;
    } on FormatException {
      return null;
    }
  }

  /// 方向分级取证，命中即停：
  /// 1. 选中金额行自带正负号（微信 / 支付宝账单的「-25.00」「+25.00」）；
  /// 2. 页面标题 / 状态行（跳过状态栏那几行后的前几行，或「xx成功」那一行）；
  /// 3. 金额所在标签（退款金额 → 收入，实付 → 支出）；
  /// 4. 对方标识（转账给 / 收款方 → 支出，来自 / 向你转账 → 收入）；
  /// 5. 受限关键词兜底（收入词只留「退款成功 / 收款成功 / 已到账 / 已存入零钱」这类明确的；转账走通知模板的判定）；
  /// 6. 有金额或成功字样就当支出。
  static String? _direction(List<String> texts, String full, {required int? amount, required String? amountLine, required String? amountLabel}) {
    if (amountLine != null) {
      if (_signExpenseRe.hasMatch(amountLine)) return 'expense';
      if (_signIncomeRe.hasMatch(amountLine)) return 'income';
    }
    // 退款页：记成退款（冲减原来那笔支出），不算收入
    if (amountLabel != null && amountLabel.contains('退款')) return 'refund';
    final body = texts.where((t) => !_statusBarRe.hasMatch(t)).toList();
    final headIdx = body.indexWhere((t) => t.length <= 12 && (_headExpenseRe.hasMatch(t) || _headIncomeRe.hasMatch(t) || _headTransferRe.hasMatch(t)));
    final head = headIdx >= 0 ? body[headIdx] : (body.isEmpty ? '' : body.first);
    if (_refundRe.hasMatch(head)) return 'refund';
    if (_headTransferRe.hasMatch(head)) return 'transfer';
    if (_headIncomeRe.hasMatch(head)) return 'income';
    if (_headExpenseRe.hasMatch(head)) return 'expense';
    if (amountLabel != null) {
      if (_incomeLabelRe.hasMatch(amountLabel)) return 'income';
      if (_expenseLabelRe.hasMatch(amountLabel)) return 'expense';
    }
    if (_partyExpenseRe.hasMatch(full)) return 'expense';
    if (_partyIncomeRe.hasMatch(full)) return 'income';
    if (_refundRe.hasMatch(full) && !_wordExpenseRe.hasMatch(full)) return 'refund';
    if (TemplateMatcher.directionOf(full) == 'transfer') return 'transfer';
    if (_wordIncomeRe.hasMatch(full) && !_wordExpenseRe.hasMatch(full)) return 'income';
    if (_wordExpenseRe.hasMatch(full)) return 'expense';
    if (_wordIncomeRe.hasMatch(full)) return 'income';
    return _successRe.hasMatch(full) || amount != null ? 'expense' : null;
  }

  // ---------------------------------------------------------------- 账单列表（多笔）
  // 微信 / 支付宝「账单」页、银行流水页：一屏好几笔，每笔一行带正负号的金额，上面是商户、旁边是时间
  static final _listAmountRe = RegExp(r'^\s*([-−+])\s*[¥￥]?\s*(\d{1,3}(?:,\d{3})+\.\d{2}|\d+\.\d{2})\s*$');
  static final _listTimeRe = RegExp(r'^(?:(今天|昨天)|(?:(20\d{2})[-/.年])?(\d{1,2})[-/.月](\d{1,2})日?)\s*(\d{1,2})[:：](\d{2})');
  static final _listNoiseRe = RegExp(r'^(账单|全部|筛选|统计|本月|支出|收入|收支|查找|搜索|月账单|\d{4}年\d{1,2}月|\d{1,2}月)');

  /// 账单列表截图 → 多笔；不像列表（带正负号的金额行少于 2 个，或者页面顶上是「支付成功」这类单笔页标题）返回空列表。
  static List<LocalShot> parseList(List<OcrLine> lines, {DateTime? fallbackTime}) {
    final texts = [for (final l in lines) l.text.trim()].where((t) => t.isNotEmpty).toList();
    final amountIdx = [for (var i = 0; i < texts.length; i++) if (_listAmountRe.hasMatch(texts[i])) i];
    if (amountIdx.length < 2) return const [];
    final body = texts.where((t) => !_statusBarRe.hasMatch(t)).take(4);
    if (body.any((t) => t.length <= 12 && (_headExpenseRe.hasMatch(t) || _headIncomeRe.hasMatch(t) || _headTransferRe.hasMatch(t)))) return const [];
    final base = fallbackTime ?? DateTime.now();
    // 版式：时间在金额下面（微信 / 支付宝账单）还是上面（部分银行流水）。看第一笔金额的下一行是不是时间
    final first = amountIdx.first;
    final timeBelow = first + 1 < texts.length && _listTime(texts[first + 1], base) != null;
    final out = <LocalShot>[];
    for (var k = 0; k < amountIdx.length; k++) {
      final i = amountIdx[k];
      final m = _listAmountRe.firstMatch(texts[i])!;
      final amount = _minor(m.group(2)!);
      if (amount == null || amount <= 0) continue;
      final sign = m.group(1)!;
      // 商户：往上找第一行「不是金额、不是时间、不是表头噪音」的文字，但不越过上一笔的金额行
      final floor = k == 0 ? -1 : amountIdx[k - 1];
      String? merchant;
      DateTime? when;
      for (var j = i - 1; j > floor; j--) {
        final t = texts[j];
        final tt = _listTime(t, base);
        if (tt != null) {
          if (!timeBelow) when ??= tt; // 时间在上面的版式才归这一笔；时间在下面的版式里，上方的时间属于上一笔
          continue;
        }
        if (merchant == null && !_listNoiseRe.hasMatch(t) && !_strongAmountRe.hasMatch(t) && t.length >= 2 && t.length <= 30) merchant = t;
      }
      final ceil = k + 1 < amountIdx.length ? amountIdx[k + 1] : texts.length;
      if (timeBelow) {
        for (var j = i + 1; j < ceil && j <= i + 2 && when == null; j++) {
          when = _listTime(texts[j], base);
        }
      }
      if (when != null && when.isAfter(base.add(const Duration(days: 1)))) when = null;
      final all = texts.sublist(floor + 1, ceil).join('\n');
      out.add(LocalShot(
        amountMinor: amount,
        direction: sign == '+' ? (RegExp('退款').hasMatch(all) ? 'refund' : 'income') : 'expense',
        merchant: merchant,
        accountHint: null,
        occurredAt: when,
        confidence: merchant == null ? 0.5 : 0.6,
        looksLikeTransaction: true,
        text: all,
      ));
    }
    return out.length >= 2 ? out : const [];
  }

  static DateTime? _listTime(String t, DateTime base) {
    final m = _listTimeRe.firstMatch(t);
    if (m == null) return null;
    final h = int.parse(m.group(5)!), mi = int.parse(m.group(6)!);
    if (m.group(1) != null) {
      final d = m.group(1) == '昨天' ? base.subtract(const Duration(days: 1)) : base;
      return DateTime(d.year, d.month, d.day, h, mi);
    }
    final y = m.group(2) != null ? int.parse(m.group(2)!) : base.year;
    final mo = int.parse(m.group(3)!), d = int.parse(m.group(4)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final dt = DateTime(y, mo, d, h, mi);
    return dt.month == mo ? dt : null;
  }

  static LocalShot parse(List<OcrLine> lines, {DateTime? fallbackTime}) {
    final texts = [for (final l in lines) l.text.trim()].where((t) => t.isNotEmpty).toList();
    final full = texts.join('\n');
    final hasStrongAmount = _strongAmountRe.hasMatch(full);
    final hasMoneyWord = _moneyWordRe.hasMatch(full);
    if (!hasStrongAmount || !hasMoneyWord) return LocalShot(looksLikeTransaction: false, text: full);

    // 金额：标签行（同一行或下一行）优先；明确标签先找，「xx金额」泛标签后找
    int? amount;
    String? amountLine; // 金额取自哪一行（正负号在这行上）
    String? amountLabel; // 金额来自哪个标签行（退款金额 / 实付…）
    var confidence = 0.55;
    for (final labelRe in [_amountLabelRe, _amountLabelLooseRe]) {
      for (var i = 0; i < texts.length && amount == null; i++) {
        final t = texts[i];
        if (!labelRe.hasMatch(t) || _notAmountLabelRe.hasMatch(t)) continue;
        for (final cand in [t.replaceFirst(labelRe, ''), if (i + 1 < texts.length) texts[i + 1]]) {
          final m = _strongAmountRe.firstMatch(cand) ?? (RegExp(r'\d').hasMatch(cand) ? _amountRe.firstMatch(cand) : null);
          final v = m?.group(1) ?? m?.group(2);
          final minor = v == null ? null : _minor(v);
          if (minor != null && minor > 0) {
            amount = minor;
            amountLine = cand;
            amountLabel = t;
            confidence = 0.75;
            break;
          }
        }
      }
      if (amount != null) break;
    }
    // 没标签：带 ¥ 且字最大的那行（成功页的大字）；再没有就第一个带两位小数的
    if (amount == null) {
      OcrLine? best;
      int? bestMinor;
      for (final l in lines) {
        final m = _strongAmountRe.firstMatch(l.text);
        if (m == null) continue;
        final v = m.group(1) ?? m.group(2);
        final minor = v == null ? null : _minor(v);
        if (minor == null || minor <= 0) continue;
        final hasSign = l.text.contains('¥') || l.text.contains('￥');
        final score = l.height + (hasSign ? 1000 : 0);
        final bestScore = best == null ? -1 : best.height + ((best.text.contains('¥') || best.text.contains('￥')) ? 1000 : 0);
        if (score > bestScore) {
          best = l;
          bestMinor = minor;
        }
      }
      amount = bestMinor;
      amountLine = best?.text;
      confidence = best != null && (best.text.contains('¥') || best.text.contains('￥')) ? 0.65 : 0.5;
    }

    final direction = _direction(texts, full, amount: amount, amountLine: amountLine, amountLabel: amountLabel);

    // 商户
    String? merchant;
    for (var i = 0; i < texts.length && merchant == null; i++) {
      final m = _merchantLabelRe.firstMatch(texts[i]);
      if (m == null) continue;
      final inline = m.group(2)!.trim();
      final cand = inline.isNotEmpty ? inline : (i + 1 < texts.length ? texts[i + 1] : '');
      if (cand.length >= 2 && cand.length <= 30 && !_noiseRe.hasMatch(cand) && !_strongAmountRe.hasMatch(cand)) merchant = cand;
    }
    if (merchant == null) {
      final at = texts.indexWhere(_successRe.hasMatch);
      if (at >= 0) {
        for (var j = at + 1; j < texts.length && j < at + 5; j++) {
          final c = texts[j];
          if (c.length >= 2 && c.length <= 30 && !_noiseRe.hasMatch(c) && !_strongAmountRe.hasMatch(c) && !RegExp(r'\d{4,}').hasMatch(c)) {
            merchant = c;
            break;
          }
        }
      }
    }

    // 时间
    DateTime? when;
    final dm = _dateRe.firstMatch(full);
    if (dm != null) {
      final y = int.parse(dm.group(1)!), mo = int.parse(dm.group(2)!), d = int.parse(dm.group(3)!);
      final h = int.tryParse(dm.group(4) ?? '') ?? 12, mi = int.tryParse(dm.group(5) ?? '') ?? 0;
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) when = DateTime(y, mo, d, h, mi);
    } else {
      final sm = _shortDateRe.firstMatch(full);
      if (sm != null) {
        final base = fallbackTime ?? DateTime.now();
        final mo = int.parse(sm.group(1)!), d = int.parse(sm.group(2)!);
        if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) when = DateTime(base.year, mo, d, int.parse(sm.group(3)!), int.parse(sm.group(4)!));
      }
    }
    if (when != null && fallbackTime != null && when.isAfter(fallbackTime.add(const Duration(days: 1)))) when = null; // 未来的日期不可信

    String? accountHint;
    for (final e in _accountHints.entries) {
      if (e.key.hasMatch(full)) {
        accountHint = e.value;
        break;
      }
    }

    return LocalShot(
      amountMinor: amount,
      direction: direction,
      merchant: merchant,
      accountHint: accountHint,
      occurredAt: when,
      confidence: merchant == null ? confidence - 0.1 : confidence,
      looksLikeTransaction: true,
      text: full,
    );
  }
}
