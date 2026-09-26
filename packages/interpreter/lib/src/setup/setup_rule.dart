import 'package:ledger_core/ledger_core.dart';

import '../context.dart';
import 'setup_numbers.dart';

/// 规则解析的结果。
class SetupParse {
  final List<SetupItem> items;
  /// 规则能完全说清：每一项都有主金额（或能按期数推出来），而且没有分不出用途的数。不完全的交给模型再看一遍（配了的话）。
  final bool complete;
  /// 分不出用途的数（给人看，也用来判断要不要问模型）。
  final List<String> unassigned;
  const SetupParse(this.items, {required this.complete, this.unassigned = const []});
}

// ------------------------------------------------------------------ 词表

/// 信用额度类（按账单还）：词 → 产品。
const _creditWords = <(String, CreditProduct)>[
  ('抖音月付', CreditProduct.douyin),
  ('微信分付', CreditProduct.fenfu),
  ('京东白条', CreditProduct.baitiao),
  ('信用卡', CreditProduct.bank),
  ('花呗', CreditProduct.huabei),
  ('白条', CreditProduct.baitiao),
  ('分付', CreditProduct.fenfu),
  ('月付', CreditProduct.douyin),
];

/// 贷款类：词 → (种类, 默认名字)。
const _loanWords = <(String, DebtKind, String)>[
  ('公积金贷款', DebtKind.mortgage, '公积金贷款'),
  ('助学贷款', DebtKind.other, '助学贷款'),
  ('京东金条', DebtKind.online, '京东金条'),
  ('房贷', DebtKind.mortgage, '房贷'),
  ('车贷', DebtKind.car, '车贷'),
  ('借呗', DebtKind.online, '借呗'),
  ('微粒贷', DebtKind.online, '微粒贷'),
  ('金条', DebtKind.online, '京东金条'),
  ('网贷', DebtKind.online, '网贷'),
  ('消费贷', DebtKind.online, '消费贷'),
  ('信用贷', DebtKind.online, '信用贷'),
  ('装修贷', DebtKind.other, '装修贷'),
  ('经营贷', DebtKind.other, '经营贷'),
  ('贷款', DebtKind.other, '贷款'),
];

/// 资产类：词 → (账户类型, 是不是定期, 默认名字；null = 按银行名拼)。
const _assetWords = <(String, AccountType, bool, String?)>[
  ('大额存单', AccountType.investment, true, null),
  ('定期存款', AccountType.investment, true, null),
  ('定期', AccountType.investment, true, null),
  ('存单', AccountType.investment, true, null),
  ('余额宝', AccountType.investment, false, '余额宝'),
  ('零钱通', AccountType.investment, false, '零钱通'),
  ('理财通', AccountType.investment, false, '理财通'),
  ('理财', AccountType.investment, false, '理财'),
  ('基金', AccountType.investment, false, '基金'),
  ('股票', AccountType.investment, false, '股票账户'),
  ('国债', AccountType.investment, false, '国债'),
  ('公积金', AccountType.investment, false, '公积金'),
  ('微信零钱', AccountType.eWallet, false, '微信'),
  ('微信余额', AccountType.eWallet, false, '微信'),
  ('支付宝余额', AccountType.eWallet, false, '支付宝'),
  ('现金', AccountType.cash, false, '现金'),
  ('活期', AccountType.bank, false, null),
  ('储蓄卡', AccountType.bank, false, null),
  ('银行卡', AccountType.bank, false, null),
  ('卡里', AccountType.bank, false, null),
  ('卡上', AccountType.bank, false, null),
  ('存款', AccountType.bank, false, null),
];

/// 银行简称：说法 → 统一的键（判断「招行」和「招商银行」是不是同一家）。
const _banks = <String, String>{
  '工商银行': '工行', '工行': '工行', '建设银行': '建行', '建行': '建行', '农业银行': '农行', '农行': '农行',
  '中国银行': '中行', '中行': '中行', '招商银行': '招行', '招行': '招行', '交通银行': '交行', '交行': '交行',
  '邮储银行': '邮储', '邮政储蓄': '邮储', '邮储': '邮储', '邮政': '邮储', '浦发银行': '浦发', '浦发': '浦发',
  '中信银行': '中信', '中信': '中信', '光大银行': '光大', '光大': '光大', '民生银行': '民生', '民生': '民生',
  '兴业银行': '兴业', '兴业': '兴业', '平安银行': '平安', '平安': '平安', '华夏银行': '华夏', '华夏': '华夏',
  '广发银行': '广发', '广发': '广发', '网商银行': '网商', '网商': '网商', '微众银行': '微众', '微众': '微众',
};
final _bankAnyRe = RegExp('(${(_banks.keys.toList()..sort((a, b) => b.length - a.length)).join('|')}|[一-龥]{2,4}银行)');

String? bankKeyOf(String s) {
  final m = _bankAnyRe.firstMatch(s);
  if (m == null) return null;
  return _banks[m.group(1)!] ?? m.group(1)!;
}

// 负债「现状」词：只有带了它们才算在说欠款（「白条还款 1000」「还花呗 500」是在记一笔还款，不是建档）
final _debtStateRe = RegExp(r'欠|还剩|剩下|剩余|剩|待还|没还|未还|月供|每月|每个月|每期|本金|总共|一共|贷了|[\d一二两三四五六七八九十]+\s*期');
final _creditStateRe = RegExp('欠|还剩|剩下|剩余|剩|待还|没还|未还|账单|额度');
// 问句：不是建档（「白条还欠多少」是查询）
final _questionRe = RegExp(r'[?？吗]|多少|几号|几期|几个月|多久|什么时候|怎么|哪个|哪些|是不是|有没有');
// 动作：在记一笔账（「还了白条 1000」「借给小李 3000」「余额宝收益 12」）。「还了 3 期」是在说期数，不算
final _eventRe = RegExp(r'花了|付了|买了|收到|到账|入账|还了(?!\s*[\d一二三四五六七八九十两]+\s*期)|还款了|转给|转出|转了|充了|充值|取了|取出|提现|支付|消费|退款|退了|收益|分红|返现|红包|利息(?![^，,。；;]*(%|百分之))|发工资|工资到|发了|赚了|亏了|赔了|刷了|扣了|交了|缴了|存了|存入|转入|存到|转到|借给|借了|报销|买(?!的)|申购|赎回|定投|投了|(存|转|取)(?=\s*[\d零〇一二两三四五六七八九十百千万])');
// 资产的动作（「存了一万定期」「买了 5000 基金」）：可能是从已有账户转过去的，要问
final _assetActionRe = RegExp(r'存了|存入|存到|转了|转入|转到|放了|(存|转)(?=\s*[\d零〇一二两三四五六七八九十百千万])');
const _depositVerbs = {'存了', '存入', '存到', '转了', '转入', '转到', '放了', '存', '转'};

final _cancelRe = RegExp('算了|不建了|取消|不用了|不要了|不弄了');

final _creditRe = RegExp(_creditWords.map((w) => w.$1).join('|'));
final _loanRe = RegExp(_loanWords.map((w) => w.$1).join('|'));
final _assetRe = RegExp('${_assetWords.map((w) => w.$1).join('|')}|(手上|手里|身上)(还)?有');
// 别人欠我：「小李欠我 3000」「借给小李的 3000 还没还」
// 「欠我」后面直接跟数 / 钱才是别人欠我（「还欠我妈两万」是我欠我妈）
final _receivableRe = RegExp(r'([一-龥A-Za-z]{1,6}?)欠我(?=\s*[\d零〇一二两三四五六七八九十百千万]|的?钱)|借给([一-龥A-Za-z]{1,6}?)的?(?=[\d零〇一二两三四五六七八九十百千万]).*?(还没还|没还|未还)');
// 我欠某人：「欠小王 5000」「还欠我妈两万」「跟我妈借了 2 万还没还」。人名不能以数字 / 「了」开头（「花呗欠了两千五」不是欠「两」）
final _personLoanRe = RegExp(
    r'欠了?(?![款费条着了零〇一二两三四五六七八九十百千万\d])(?!我(?=\s*[\d零〇一二两三四五六七八九十百千万]|的?钱))([一-龥A-Za-z]{1,6}?)(的钱|的)?\s*(?=[\d零〇一二两三四五六七八九十百千万])'
    r'|(跟|向|找)((?![零〇一二两三四五六七八九十百千万\d])[一-龥A-Za-z]{1,6}?)借了?.*?(还没还|没还|未还|还欠)');

class _Subject {
  final int start;
  final int end;
  final SetupKind kind;
  final String word;
  final CreditProduct? product;
  final (String, DebtKind, String)? loan;
  final (String, AccountType, bool, String?)? asset;
  final String? person;
  _Subject(this.start, this.end, this.kind, this.word, {this.product, this.loan, this.asset, this.person});
}

/// 人名前面粘上的连接词（「还有小李欠我」「另外跟我妈借了」）去掉。
String _stripLead(String who) => who.replaceFirst(RegExp('^(还有|另外|以及|然后|而且|和|跟|与|我还|还)+'), '');

List<_Subject> _findSubjects(String s) {
  final found = <_Subject>[];
  for (final m in _creditRe.allMatches(s)) {
    final w = m.group(0)!;
    found.add(_Subject(m.start, m.end, SetupKind.credit, w, product: _creditWords.firstWhere((x) => x.$1 == w).$2));
  }
  for (final m in _loanRe.allMatches(s)) {
    final w = m.group(0)!;
    found.add(_Subject(m.start, m.end, SetupKind.loan, w, loan: _loanWords.firstWhere((x) => x.$1 == w)));
  }
  for (final m in _assetRe.allMatches(s)) {
    final w = m.group(0)!;
    final def = _assetWords.where((x) => x.$1 == w).firstOrNull ?? ('现金', AccountType.cash, false, '现金');
    found.add(_Subject(m.start, m.end, SetupKind.asset, w, asset: def));
  }
  for (final m in _receivableRe.allMatches(s)) {
    final who = _stripLead((m.group(1) ?? m.group(2) ?? '').trim());
    if (who.isEmpty) continue;
    found.add(_Subject(m.start, m.end, SetupKind.receivable, m.group(0)!, person: who));
  }
  for (final m in _personLoanRe.allMatches(s)) {
    final who = _stripLead((m.group(1) ?? m.group(4) ?? '').trim());
    if (who.isEmpty || _creditRe.hasMatch(who) || _loanRe.hasMatch(who) || _assetRe.hasMatch(who)) continue;
    found.add(_Subject(m.start, m.end, SetupKind.loan, m.group(0)!, loan: ('', DebtKind.loan, '欠$who'), person: who));
  }
  // 重叠的留长的（「公积金贷款」不是「公积金」+「贷款」；「京东白条」不是「白条」）
  found.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : (b.end - b.start).compareTo(a.end - a.start));
  final out = <_Subject>[];
  for (final f in found) {
    if (out.isNotEmpty && f.start < out.last.end) {
      if ((f.end - f.start) > (out.last.end - out.last.start)) out[out.length - 1] = f;
      continue;
    }
    out.add(f);
  }
  return out;
}

/// 一句话 → 建档项。不像在说负债 / 资产就返回 null（交还给记账解析，行为和以前一样）。
/// [explicit] = 用户点了「登记负债 / 资产」再说的：不做问句 / 动作排除。
SetupParse? parseSetupRule(String raw, InterpretContext ctx, {bool explicit = false, required String today}) {
  final s = normalizeSetupText(raw.trim());
  if (s.isEmpty) return null;
  if (!explicit && _questionRe.hasMatch(s)) return null;
  final subjects = _findSubjects(s);
  if (subjects.isEmpty) return null;
  final nums = extractSetupNumbers(s);
  final hasMoney = nums.any((n) => n.kind == NumKind.money);
  if (!explicit && !hasMoney) return null;

  final assetAction = _assetActionRe.hasMatch(s);
  if (!explicit) {
    // 动作句只有两种放行：资产的「存了 / 转了」（全是资产项、且只有存 / 转这类动作）、「跟 X 借了……还没还」「借给 X 的……还没还」
    final events = _eventRe.allMatches(s).map((m) => m.group(0)!).toList();
    final onlyAssets = subjects.every((x) => x.kind == SetupKind.asset);
    final owedPhrase = RegExp('还没还|没还|未还|还欠').hasMatch(s);
    final depositOnly = onlyAssets && events.every(_depositVerbs.contains);
    final borrowOnly = owedPhrase && events.every((e) => e == '借了' || e == '借给');
    if (events.isNotEmpty && !depositOnly && !borrowOnly) return null;
    // 负债项要带「现状」词
    for (final x in subjects) {
      if (x.kind == SetupKind.credit && !_creditStateRe.hasMatch(s)) return null;
      if (x.kind == SetupKind.loan && x.person == null && !_debtStateRe.hasMatch(s)) return null;
    }
  }

  // ---- 切段：按标点切成小句；一个小句里有多个主体就在后一个主体前再切（连接词算前一段）
  final bounds = <(int, int)>[];
  var st = 0;
  for (final m in RegExp(r'[，,。；;！!\n]|另外|还有|以及').allMatches(s)) {
    if (m.start > st) bounds.add((st, m.start));
    st = m.end;
  }
  if (st < s.length) bounds.add((st, s.length));
  final pieces = <(int, int, _Subject?)>[];
  for (final (a, b) in bounds) {
    final inside = subjects.where((x) => x.start >= a && x.start < b).toList();
    if (inside.isEmpty) {
      pieces.add((a, b, null));
      continue;
    }
    var from = a;
    for (var k = 0; k < inside.length; k++) {
      final to = k + 1 < inside.length ? _cutBefore(s, inside[k + 1].start, inside[k].end) : b;
      pieces.add((from, to, inside[k]));
      from = to;
    }
  }
  // 没主体的小句挂到前一项（开头的挂到后一项）
  final groups = <(_Subject, List<(int, int)>)>[];
  final leading = <(int, int)>[];
  for (final (a, b, sub) in pieces) {
    if (sub != null) {
      groups.add((sub, [...leading, (a, b)]));
      leading.clear();
    } else if (groups.isNotEmpty) {
      groups.last.$2.add((a, b));
    } else {
      leading.add((a, b));
    }
  }

  final items = <SetupItem>[];
  final unassigned = <String>[];
  for (final (sub, ranges) in groups) {
    bool inRanges(int p) => ranges.any((r) => p >= r.$1 && p < r.$2);
    final text = ranges.map((r) => s.substring(r.$1, r.$2)).join('，');
    final toks = nums.where((n) => inRanges(n.start)).toList();
    final it = _buildItem(sub, s, text, toks, ctx, today: today, assetAction: assetAction, unassigned: unassigned);
    items.add(it);
  }
  // 资产的动作句碰上已有账户（「存了 500 到余额宝」）：那是往已有账户里存钱，交还记账解析
  items.removeWhere((it) => it.existingAccountId != null && it.viaAction);
  if (items.isEmpty) return null;
  // 全是已有账户、又说了「余额 / 还剩」（「微信余额 500」「微信零钱还剩 300」）：记账那边一直当余额查询，交还给它
  if (!explicit && items.every((it) => it.existingAccountId != null) && RegExp('余额(?!宝)|还剩|剩下|剩余').hasMatch(s)) return null;
  final complete = unassigned.isEmpty && items.every((it) => it.principalMinor != null || ((it.monthlyMinor ?? 0) > 0 && (it.periods ?? 0) > 0));
  return SetupParse(items, complete: complete, unassigned: unassigned);
}

/// 两个主体之间切开：连接词（和 / 跟 / 欠 / 还有）算后一段的开头。
int _cutBefore(String s, int nextStart, int prevEnd) {
  var i = nextStart;
  while (i > prevEnd && RegExp('[欠和跟与及]').hasMatch(s[i - 1])) {
    i--;
  }
  return i;
}

SetupItem _buildItem(_Subject sub, String whole, String text, List<NumToken> toks, InterpretContext ctx, {required String today, required bool assetAction, required List<String> unassigned}) {
  final bankWordM = _bankAnyRe.firstMatch(text);
  final bankWord = bankWordM?.group(1);
  late final SetupItem it;
  switch (sub.kind) {
    case SetupKind.credit:
      final p = sub.product!;
      final monthlyHint = RegExp('每月|每个月|月供|每期|分期').hasMatch(text) || toks.any((t) => t.kind == NumKind.periods);
      if (monthlyHint) {
        // 说了固定月供 / 分期：按分期借款建（每月固定还多少、还清为止）
        it = SetupItem(kind: SetupKind.loan, name: p == CreditProduct.bank ? '${bankWord ?? ''}信用卡分期' : p.label, debtKind: DebtKind.online, product: p);
        it.notes.add('说了每月固定还，按分期借款建');
      } else {
        it = SetupItem(kind: SetupKind.credit, name: p == CreditProduct.bank ? '${bankWord ?? ''}信用卡' : p.label, product: p);
      }
    case SetupKind.loan:
      final (_, kind, defName) = sub.loan!;
      final name = sub.person != null ? defName : (defName == '贷款' && bankWord != null ? '$bankWord贷款' : defName);
      it = SetupItem(kind: SetupKind.loan, name: name, debtKind: kind);
    case SetupKind.asset:
      final (_, type, deposit, defName) = sub.asset!;
      String name;
      if (defName != null) {
        name = defName;
      } else if (deposit) {
        name = '${bankWord ?? ''}${sub.word == '大额存单' ? '大额存单' : '定期'}';
        if (bankWord == null && sub.word != '大额存单') name = '定期存款';
      } else {
        name = bankWord ?? (sub.word == '存款' ? '存款' : (text.contains('工资卡') ? '工资卡' : '银行卡'));
      }
      it = SetupItem(kind: SetupKind.asset, name: name, assetType: type, deposit: deposit, viaAction: assetAction);
    case SetupKind.receivable:
      it = SetupItem(kind: SetupKind.receivable, name: '借给${sub.person}');
  }

  // ---- 数字分配
  int? paidPeriods;
  int? totalPeriods;
  // 每个数往前看的「上下文」：金额看到上一个金额为止（「每月 15 号还 1000」的「每月」要看得见），其余看到上一个数为止
  var prevAny = 0;
  var prevMoney = 0;
  final itemText = text;
  for (final t in toks) {
    final from = t.kind == NumKind.money ? prevMoney : prevAny;
    final win = whole.substring(from < t.start ? _windowStart(whole, t.start, from) : t.start, t.start);
    final after = whole.substring(t.end, t.end + 4 > whole.length ? whole.length : t.end + 4);
    prevAny = t.end;
    if (t.kind == NumKind.money) prevMoney = t.end;
    switch (t.kind) {
      case NumKind.money:
        final label = Money(t.value, t.currency).toDecimalString();
        if (it.kind == SetupKind.loan || it.kind == SetupKind.credit) {
          final monthlyish = RegExp('每月|每个月|月供|每期|一个月|一月|月还').hasMatch(win) || RegExp(r'^\s*(/月|一个月|一期|每期)').hasMatch(after);
          if (RegExp('额度').hasMatch(win)) {
            if (it.kind == SetupKind.credit && it.limitMinor == null) {
              it.limitMinor = t.value;
            } else {
              unassigned.add(label);
            }
          } else if (monthlyish) {
            if (it.kind == SetupKind.loan && it.monthlyMinor == null) {
              it.monthlyMinor = t.value;
            } else {
              unassigned.add(label);
            }
          } else if (RegExp('欠|剩|余|本金|总共|一共|共|贷了|借了|待还|未还|没还|账单|总额').hasMatch(win) && it.principalMinor == null) {
            it.principalMinor = t.value;
            it.currency = t.currency;
            it.approx = t.approx;
          } else if (it.principalMinor == null) {
            it.principalMinor = t.value;
            it.currency = t.currency;
            it.approx = t.approx;
          } else if (it.kind == SetupKind.loan && it.monthlyMinor == null && RegExp('还').hasMatch(win)) {
            it.monthlyMinor = t.value;
          } else {
            unassigned.add(label);
          }
        } else {
          if (it.principalMinor == null) {
            it.principalMinor = t.value;
            it.currency = t.currency;
            it.approx = t.approx;
          } else {
            unassigned.add(label);
          }
        }
      case NumKind.periods:
        if (it.kind != SetupKind.loan) break;
        if (RegExp('已还|还了|已经还').hasMatch(win)) {
          paidPeriods = t.value;
        } else if (RegExp('共|总共|一共|分').hasMatch(win)) {
          totalPeriods = t.value;
        } else {
          it.periods ??= t.value;
        }
      case NumKind.day:
        if (it.kind == SetupKind.loan) {
          it.day ??= t.value;
        } else if (it.kind == SetupKind.credit) {
          if (RegExp('账单|出账').hasMatch(win)) {
            it.statementDay ??= t.value;
          } else {
            it.dueDay ??= t.value;
          }
        }
      case NumKind.percent:
        if (it.kind == SetupKind.asset && t.percent > 0 && t.percent < 30) it.ratePercent ??= t.percent;
      case NumKind.termMonths:
        if (it.kind == SetupKind.asset && it.deposit) it.termMonths ??= t.value;
    }
  }
  if (it.kind == SetupKind.loan && it.periods == null) {
    if (totalPeriods != null && paidPeriods != null && totalPeriods > paidPeriods) {
      it.periods = totalPeriods - paidPeriods;
    } else if (totalPeriods != null && paidPeriods == null) {
      it.periods = totalPeriods;
    }
  }
  if (it.approx) it.notes.add('金额是估的，可以点开改准');

  // ---- 日子
  if (it.kind == SetupKind.loan || it.kind == SetupKind.credit) {
    if (monthEndRe.hasMatch(itemText)) {
      if (it.kind == SetupKind.loan) it.day ??= 28;
      if (it.kind == SetupKind.credit) it.dueDay ??= 28;
    }
    final d = it.kind == SetupKind.loan ? it.day : it.dueDay;
    if (d != null && d > 28) it.notes.add('$d 号按 28 号建（周期最多到 28 号）');
    if (monthEndRe.hasMatch(itemText)) it.notes.add('月底按 28 号建');
    if (it.kind == SetupKind.loan && RegExp('(下个月|下月).{0,6}开始').hasMatch(itemText)) it.startNextMonth = true;
  }
  if (it.kind == SetupKind.credit) {
    if (it.dueDay != null && it.dueDay! > 28) it.dueDay = 28;
    if (it.statementDay != null && it.statementDay! > 28) it.statementDay = 28;
  }

  // ---- 定期到期日
  if (it.kind == SetupKind.asset && it.deposit) {
    final m = parseMaturity(itemText, today);
    if (m != null) {
      it.maturity = m.$1;
      if (m.$2 != null) it.notes.add(m.$2!);
    }
  }

  // ---- 从哪个账户（「从工行卡扣」「用微信还」「从招行转了一万存定期」）
  final from = _mentionedFromAccount(itemText, ctx, exclude: it.kind == SetupKind.asset ? it.name : null) ?? _mentionedFromAccount(whole, ctx, exclude: it.kind == SetupKind.asset ? it.name : null);
  if (from != null) {
    if (it.kind == SetupKind.loan) it.fromAccountId = from;
    if (it.kind == SetupKind.asset && it.viaAction) {
      it.fromAccountId = from;
      it.fromTransfer = true;
    }
  }

  it.existingAccountId = findExistingAccount(it, ctx);
  return it;
}

/// 这个数前面的「上下文」：从上一个数结束（或小句开头）到它。
int _windowStart(String s, int start, int prevEnd) {
  var i = start;
  while (i > prevEnd && !RegExp(r'[，,。；;！!\n]').hasMatch(s[i - 1])) {
    i--;
  }
  return i;
}

const _liquidTypes = {'cash', 'bank', 'e_wallet'};

String? _mentionedFromAccount(String text, InterpretContext ctx, {String? exclude}) {
  final accs = [...ctx.accounts]..sort((a, b) => b.name.length - a.name.length);
  for (final a in accs) {
    if (a.type != null && !_liquidTypes.contains(a.type)) continue;
    if (exclude != null && a.name == exclude) continue;
    final names = {a.name, ...a.aliases};
    final bk = bankKeyOf(a.name);
    if (bk != null) {
      for (final e in _banks.entries) {
        if (e.value == bk) names.add(e.key);
      }
    }
    for (final n in names) {
      if (n.isEmpty) continue;
      final q = RegExp.escape(n);
      if (RegExp('(从|用|由|拿)\\s*$q').hasMatch(text) || RegExp('$q(卡)?\\s*(里)?\\s*(自动)?(扣|扣款|还|转)').hasMatch(text)) return a.id;
    }
  }
  return null;
}

String _norm(String s) => s.replaceAll(RegExp(r'\s'), '').toLowerCase();

/// 已经有这个账户了吗（有就不新建，卡片上指路）。
String? findExistingAccount(SetupItem it, InterpretContext ctx) {
  final n = _norm(it.name);
  for (final a in ctx.accounts) {
    if (_norm(a.name) == n) return a.id;
  }
  // 信用额度 / 分期：同一个产品（名字里带「白条」「花呗」……）算同一个
  if ((it.kind == SetupKind.credit || it.kind == SetupKind.loan) && it.product != CreditProduct.bank) {
    final key = switch (it.product) {
      CreditProduct.huabei => '花呗',
      CreditProduct.baitiao => '白条',
      CreditProduct.fenfu => '分付',
      CreditProduct.douyin => '月付',
      CreditProduct.bank => '',
    };
    for (final a in ctx.accounts) {
      if (key.isNotEmpty && a.name.contains(key) && (a.type == null || a.type == 'credit_card' || a.type == 'payable')) return a.id;
    }
  }
  // 信用卡：同一家银行的信用卡
  if ((it.kind == SetupKind.credit || it.kind == SetupKind.loan) && it.product == CreditProduct.bank && it.name.contains('信用卡')) {
    final bk = bankKeyOf(it.name);
    for (final a in ctx.accounts) {
      if (a.type == 'credit_card' && (bk == null ? _norm(a.name) == n : bankKeyOf(a.name) == bk)) return a.id;
    }
  }
  // 银行卡：同一家银行的储蓄账户
  if (it.kind == SetupKind.asset && it.assetType == AccountType.bank) {
    final bk = bankKeyOf(it.name);
    if (bk != null) {
      for (final a in ctx.accounts) {
        if ((a.type == null || a.type == 'bank') && bankKeyOf(a.name) == bk) return a.id;
      }
    }
  }
  // 没说哪家银行的「卡里还有 3000」：只有一张储蓄卡就是它
  if (it.kind == SetupKind.asset && it.assetType == AccountType.bank && it.name == '银行卡') {
    final banks = ctx.accounts.where((a) => a.type == 'bank').toList();
    if (banks.length == 1) return banks.single.id;
  }
  // 现金 / 微信 / 支付宝：同类型的同名账户上面已经比过；现金只有一个的话也算
  if (it.kind == SetupKind.asset && it.assetType == AccountType.cash) {
    final cash = ctx.accounts.where((a) => a.type == 'cash').toList();
    if (cash.length == 1) return cash.single.id;
  }
  return null;
}

/// 到期日：「2027 年 3 月 15 号到期」「明年 3 月到期」「3 月 15 号到期」「三年后到期」。返回 (yyyy-MM-dd, 说明)。
(String, String?)? parseMaturity(String text, String today) {
  final s = normalizeSetupText(text);
  if (!s.contains('到期')) {
    return null;
  }
  final ty = int.parse(today.substring(0, 4));
  final tm = int.parse(today.substring(5, 7));
  final td = int.parse(today.substring(8, 10));
  int? n(String? x) {
    if (x == null) return null;
    return int.tryParse(x) ?? parseCnSmall(x);
  }

  String fmt(int y, int m, int d) {
    final last = DateTime.utc(y, m + 1, 0).day;
    final dd = d > last ? last : d;
    return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${dd.toString().padLeft(2, '0')}';
  }

  const cn = '零〇一二两三四五六七八九十';
  final abs = RegExp('(\\d{4})\\s*年\\s*([\\d$cn]{1,3})\\s*月(?:\\s*([\\d$cn]{1,3})\\s*[号日])?').firstMatch(s);
  if (abs != null) {
    final y = int.parse(abs.group(1)!);
    final m = n(abs.group(2));
    final d = n(abs.group(3));
    if (m != null && m >= 1 && m <= 12) return (fmt(y, m, d ?? td), d == null ? '到期日没说几号，按 $td 号记' : null);
  }
  final rel = RegExp('(明年|后年|今年)\\s*([\\d$cn]{1,3})\\s*月(?:\\s*([\\d$cn]{1,3})\\s*[号日])?').firstMatch(s);
  if (rel != null) {
    final y = ty + (rel.group(1) == '明年' ? 1 : rel.group(1) == '后年' ? 2 : 0);
    final m = n(rel.group(2));
    final d = n(rel.group(3));
    if (m != null && m >= 1 && m <= 12) return (fmt(y, m, d ?? td), d == null ? '到期日没说几号，按 $td 号记' : null);
  }
  final md = RegExp('([\\d$cn]{1,3})\\s*月\\s*([\\d$cn]{1,3})\\s*[号日]').firstMatch(s);
  if (md != null) {
    final m = n(md.group(1));
    final d = n(md.group(2));
    if (m != null && d != null && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
      final passed = m < tm || (m == tm && d <= td);
      return (fmt(passed ? ty + 1 : ty, m, d), null);
    }
  }
  final after = RegExp('([\\d$cn]{1,3})\\s*(年|个月)后').firstMatch(s);
  if (after != null) {
    final k = n(after.group(1));
    if (k != null && k > 0) return (addMonths(today, after.group(2) == '年' ? k * 12 : k), null);
  }
  return null;
}

int? parseCnSmall(String s) {
  const d = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  if (s.isEmpty) return null;
  if (s == '十') return 10;
  if (s.length == 1) return d[s];
  if (s.startsWith('十')) return 10 + (d[s[1]] ?? 0);
  if (s.length == 2 && s[1] == '十') return (d[s[0]] ?? 0) * 10;
  if (s.length == 3 && s[1] == '十') return (d[s[0]] ?? 0) * 10 + (d[s[2]] ?? 0);
  return null;
}

/// 「算了 / 不建了」。
bool isSetupCancel(String s) => _cancelRe.hasMatch(s);
