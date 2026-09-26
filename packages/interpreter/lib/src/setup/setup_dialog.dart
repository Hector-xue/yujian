import 'package:ledger_core/ledger_core.dart';

import 'setup_numbers.dart';
import 'setup_rule.dart';

/// 对话建档的追问：一次只问一项，给快捷选项；用户的下一句先当成这个问题的回答，答不上就放下追问、这句照常处理。
class SetupChoice {
  final String label;
  /// 按字段：金额 / 几号 = int；账户 = String（id）；是否 = bool；跳过 = [skip]；
  final Object? value;
  const SetupChoice(this.label, this.value);
  static const skip = '__skip__';
}

class SetupQuestion {
  final int itemIndex;
  final SetupSlot slot;
  final String text;
  final List<SetupChoice> choices;
  const SetupQuestion(this.itemIndex, this.slot, this.text, this.choices);
}

/// 下一个要问的（按项的顺序）；都齐了 = null。
/// 每次先按 [env] 补上能推断的（后来才说了月供，扣款账户也要能推），推断只填空着的字段。
SetupQuestion? nextSetupQuestion(List<SetupItem> items, SetupEnv env) {
  for (var i = 0; i < items.length; i++) {
    final it = items[i]..infer(env);
    final slot = it.nextSlot(env);
    if (slot == null) continue;
    return SetupQuestion(i, slot, _questionText(it, slot, env), _choices(it, slot, env));
  }
  return null;
}

String _q(SetupItem it) => '「${it.name}」';

String _questionText(SetupItem it, SetupSlot slot, SetupEnv env) => switch (slot) {
      SetupSlot.principal => switch (it.kind) {
          SetupKind.loan || SetupKind.credit => '${_q(it)}现在还欠多少？',
          SetupKind.asset => '${_q(it)}里有多少钱？',
          SetupKind.receivable => '${it.name.replaceFirst('借给', '')}欠你多少？',
        },
      SetupSlot.monthly => '${_q(it)}每月固定还多少？没有固定月供就点「跳过」，先只记欠款。',
      SetupSlot.day => '${_q(it)}每月几号还？',
      SetupSlot.fromAccount => '${_q(it)}从哪个账户还？',
      SetupSlot.paidThisPeriod => '今天就是${_q(it)}的还款日，这期已经还了吗？',
      SetupSlot.limit => '${_q(it)}的额度是多少？',
      SetupSlot.dueDay => '${_q(it)}每月几号还款？',
      SetupSlot.statementDay => '${_q(it)}每月几号出账单？在它的账单页能看到。',
      SetupSlot.transferSource => it.fromTransfer == true ? '从哪个账户转过去的？' : '这 ${Money(it.principalMinor ?? 0, it.currency).toDecimalString()} 是从你已有的账户转过去的吗？是的话选那个账户（它的余额会少这么多），不是就单独记一笔。',
      SetupSlot.maturity => '${_q(it)}什么时候到期？比如「明年 3 月 15 号」。不记得就跳过。',
    };

List<SetupChoice> _choices(SetupItem it, SetupSlot slot, SetupEnv env) {
  List<SetupChoice> accounts() => [
        for (final a in env.liquidAccounts)
          if (a.currency == it.currency) SetupChoice(a.name, a.id),
      ].take(6).toList();
  switch (slot) {
    case SetupSlot.principal:
      return it.kind == SetupKind.credit ? const [SetupChoice('现在没欠', 0)] : const [];
    case SetupSlot.monthly:
      return const [SetupChoice('跳过', SetupChoice.skip)];
    case SetupSlot.day:
      return const [SetupChoice('1 号', 1), SetupChoice('5 号', 5), SetupChoice('10 号', 10), SetupChoice('15 号', 15), SetupChoice('20 号', 20), SetupChoice('25 号', 25)];
    case SetupSlot.fromAccount:
      return accounts();
    case SetupSlot.paidThisPeriod:
      return const [SetupChoice('已经还了，从下个月算', true), SetupChoice('还没还，今天这期也算', false)];
    case SetupSlot.limit:
      return const [];
    case SetupSlot.dueDay:
      return [for (final (_, dd) in it.product.dayOptions) SetupChoice('$dd 号', dd)];
    case SetupSlot.statementDay:
      return [
        for (final (sd, _) in it.product.dayOptions) SetupChoice('$sd 号', sd),
        const SetupChoice('不知道，按常见间隔推算', SetupChoice.skip),
      ];
    case SetupSlot.transferSource:
      return [...accounts(), if (it.fromTransfer != true) const SetupChoice('不是，单独记', false)];
    case SetupSlot.maturity:
      return const [SetupChoice('跳过', SetupChoice.skip)];
  }
}

/// 点了快捷选项。返回 false = 选项和字段对不上（不会发生，防御）。
bool applySetupChoice(SetupItem it, SetupSlot slot, SetupChoice c, SetupEnv env) {
  final v = c.value;
  switch (slot) {
    case SetupSlot.principal:
      if (v is! int || v < 0) return false;
      it.principalMinor = v;
    case SetupSlot.monthly:
      if (v == SetupChoice.skip) {
        it.asked.add(SetupSlot.monthly);
      } else if (v is int && v > 0) {
        it.monthlyMinor = v;
      } else {
        return false;
      }
    case SetupSlot.day:
      if (v is! int) return false;
      it.day = v;
    case SetupSlot.fromAccount:
      if (v is! String || env.account(v) == null) return false;
      it.fromAccountId = v;
    case SetupSlot.paidThisPeriod:
      if (v is! bool) return false;
      it.paidThisPeriod = v;
    case SetupSlot.limit:
      if (v is! int || v <= 0) return false;
      it.limitMinor = v;
    case SetupSlot.dueDay:
      if (v is! int) return false;
      it.dueDay = v > 28 ? 28 : v;
      it.statementDay = null;
      it.infer(env);
    case SetupSlot.statementDay:
      if (v == SetupChoice.skip) {
        it.statementDay = it.derivedStatementDay();
        it.notes.add('账单日按${it.product.label}常见的间隔推算成 ${it.statementDay} 号，不对可以在负债页改');
      } else if (v is int) {
        it.statementDay = v > 28 ? 28 : v;
      } else {
        return false;
      }
    case SetupSlot.transferSource:
      if (v == false) {
        it.fromTransfer = false;
        it.fromAccountId = null;
      } else if (v is String && env.account(v) != null) {
        it.fromTransfer = true;
        it.fromAccountId = v;
      } else {
        return false;
      }
    case SetupSlot.maturity:
      if (v == SetupChoice.skip) {
        it.asked.add(SetupSlot.maturity);
      } else if (v is String) {
        it.maturity = v;
      } else {
        return false;
      }
  }
  if (optionalSetupSlots.contains(slot)) it.asked.add(slot);
  return true;
}

enum SetupAnswerKind {
  answered, // 答上了，字段已填
  cancel, // 「算了」
  confirm, // 都齐了之后说「好 / 确认」
  requiredSkip, // 必填的说「不知道」：提示一句，追问还在
  notAnswer, // 不是在回答：放下追问，这句照常处理
}

final _skipRe = RegExp(r'^(跳过|不知道|不清楚|不记得|忘了|没有|没|先不|不用|没固定|不固定|不设|算不清|随便)(了|吧|啊|呢)?$');
final _confirmRe = RegExp(r'^(确认|确定|好|好的|好了|可以|行|行吧|建吧|建|没问题|对|是的|嗯|ok|OK|Ok)(的|吧|啊|了|呀)?$');
final _yesRe = RegExp('还了|已经|已还|是|对|嗯');
final _noRe = RegExp('没还|还没|没有|不是|没');
// 答一句话里除了答案外可以有的「垫词」
final _filler = RegExp(r'[，,。.！!\s]|大概|大约|差不多|估计|左右|多|吧|啊|呢|呀|的|是|有|欠|还|每月|每个月|一个月|月供|额度|块钱|块|元|钱|号|日|了|大约是|应该|可能|我|卡|账户|里|从|用|走|扣');

/// 用户打字回答 [q]。[accounts] 用来认「工行 / 微信」这类账户名。
SetupAnswerKind answerSetupQuestion(List<SetupItem> items, SetupQuestion q, String raw, SetupEnv env) {
  final text = normalizeSetupText(raw.trim());
  if (text.isEmpty) return SetupAnswerKind.notAnswer;
  if (isSetupCancel(text)) return SetupAnswerKind.cancel;
  final it = items[q.itemIndex];
  final short = text.length <= 16;
  if (short && _skipRe.hasMatch(text)) {
    if (optionalSetupSlots.contains(q.slot)) {
      applySetupChoice(it, q.slot, const SetupChoice('', SetupChoice.skip), env);
      return SetupAnswerKind.answered;
    }
    if (q.slot == SetupSlot.statementDay) {
      applySetupChoice(it, q.slot, const SetupChoice('', SetupChoice.skip), env);
      return SetupAnswerKind.answered;
    }
    return SetupAnswerKind.requiredSkip;
  }
  // 选项原样打出来（「15 号」「微信」「不是，单独记」）
  for (final c in q.choices) {
    if (_norm(c.label) == _norm(text)) return applySetupChoice(it, q.slot, c, env) ? SetupAnswerKind.answered : SetupAnswerKind.notAnswer;
  }
  // 剩下的字（去掉数和垫词）不能太多，不然就不是在回答（「午饭 25」「今天打车花了 30」）
  bool answerShaped(List<NumToken> used) {
    var rest = text;
    for (final t in used.reversed) {
      rest = rest.replaceRange(t.start, t.end, '');
    }
    rest = rest.replaceAll(_filler, '');
    return rest.length <= 1;
  }

  final nums = extractSetupNumbers(text);
  switch (q.slot) {
    case SetupSlot.principal:
    case SetupSlot.monthly:
    case SetupSlot.limit:
      // 光秃秃的数（「5000」「五千」）也算钱
      var money = nums.where((n) => n.kind == NumKind.money).toList();
      if (money.isEmpty) {
        final bare = RegExp(r'^\s*([\d.,]+|[零〇一二两三四五六七八九十百千万]+)\s*$').firstMatch(text);
        if (bare != null) money = extractSetupNumbers('${bare.group(1)}元').where((n) => n.kind == NumKind.money).toList();
        if (money.length == 1 && money.single.value > 0) {
          if (q.slot == SetupSlot.principal) it.principalMinor = money.single.value;
          if (q.slot == SetupSlot.monthly) it.monthlyMinor = money.single.value;
          if (q.slot == SetupSlot.limit) it.limitMinor = money.single.value;
          if (optionalSetupSlots.contains(q.slot)) it.asked.add(q.slot);
          return SetupAnswerKind.answered;
        }
        if (q.slot == SetupSlot.principal && it.kind == SetupKind.credit && RegExp(r'^(没欠|不欠|没有|0|零)').hasMatch(text)) {
          it.principalMinor = 0;
          return SetupAnswerKind.answered;
        }
        return SetupAnswerKind.notAnswer;
      }
      final extraDay = q.slot == SetupSlot.monthly ? nums.where((n) => n.kind == NumKind.day).take(1).toList() : const <NumToken>[];
      if (money.length != 1 || !answerShaped([...money, ...extraDay]..sort((a, b) => a.start.compareTo(b.start)))) return SetupAnswerKind.notAnswer;
      final v = money.single.value;
      if (q.slot == SetupSlot.principal) {
        it.principalMinor = v;
        it.approx = money.single.approx;
      }
      if (q.slot == SetupSlot.monthly) it.monthlyMinor = v;
      if (q.slot == SetupSlot.limit) it.limitMinor = v;
      if (optionalSetupSlots.contains(q.slot)) it.asked.add(q.slot);
      // 答月供时顺带说了几号（「1000，15 号」）
      if (q.slot == SetupSlot.monthly) {
        final d = nums.where((n) => n.kind == NumKind.day).firstOrNull;
        if (d != null) it.day = d.value;
      }
      return SetupAnswerKind.answered;
    case SetupSlot.day:
    case SetupSlot.dueDay:
    case SetupSlot.statementDay:
      int? day = nums.where((n) => n.kind == NumKind.day).firstOrNull?.value;
      final used = nums.where((n) => n.kind == NumKind.day).take(1).toList();
      if (day == null) {
        final bare = RegExp(r'^\s*(?:每月|每个月)?\s*(\d{1,2}|[一二三四五六七八九十]{1,3})\s*$').firstMatch(text);
        if (bare != null) day = int.tryParse(bare.group(1)!) ?? parseCnSmall(bare.group(1)!);
        if (day == null && monthEndRe.hasMatch(text) && text.length <= 6) day = 28;
        if (day == null) return SetupAnswerKind.notAnswer;
      } else if (!answerShaped(used)) {
        return SetupAnswerKind.notAnswer;
      }
      if (day < 1 || day > 31) return SetupAnswerKind.notAnswer;
      final c = SetupChoice('', day > 28 ? 28 : day);
      if (day > 28) it.notes.add('$day 号按 28 号建（周期最多到 28 号）');
      return applySetupChoice(it, q.slot, c, env) ? SetupAnswerKind.answered : SetupAnswerKind.notAnswer;
    case SetupSlot.fromAccount:
    case SetupSlot.transferSource:
      if (q.slot == SetupSlot.transferSource && short && RegExp(r'^(不是|没有|不|单独|单独记|不是转的|原来就有|本来就有)').hasMatch(text)) {
        applySetupChoice(it, q.slot, const SetupChoice('', false), env);
        return SetupAnswerKind.answered;
      }
      final id = _matchAccount(text, env, it.currency);
      if (id == null) return SetupAnswerKind.notAnswer;
      // 只说了账户（「微信」「从工行卡扣」），不是一句带账户名的记账（「午饭用微信付了 25」）
      final acc = env.account(id)!;
      var rest = text.replaceAll(acc.name, '');
      final bk = bankKeyOf(rest);
      if (bk != null) rest = rest.replaceAll(RegExp('工商银行|建设银行|农业银行|中国银行|招商银行|交通银行|[一-龥]{1,4}银行|工行|建行|农行|中行|招行|交行|邮储|浦发|中信|光大|民生|兴业|平安|华夏|广发|网商|微众'), '');
      rest = rest.replaceAll(_filler, '').replaceAll(RegExp('自动|转|转过去|转的|是|那个|这个|这张'), '');
      if (rest.length > 1 || nums.any((n) => n.kind == NumKind.money)) return SetupAnswerKind.notAnswer;
      return applySetupChoice(it, q.slot, SetupChoice('', id), env) ? SetupAnswerKind.answered : SetupAnswerKind.notAnswer;
    case SetupSlot.paidThisPeriod:
      if (!short) return SetupAnswerKind.notAnswer;
      if (_noRe.hasMatch(text)) {
        it.paidThisPeriod = false;
        return SetupAnswerKind.answered;
      }
      if (_yesRe.hasMatch(text)) {
        it.paidThisPeriod = true;
        return SetupAnswerKind.answered;
      }
      return SetupAnswerKind.notAnswer;
    case SetupSlot.maturity:
      final m = parseMaturity(text.contains('到期') ? text : '$text到期', env.today);
      if (m == null) return SetupAnswerKind.notAnswer;
      it.maturity = m.$1;
      if (m.$2 != null) it.notes.add(m.$2!);
      it.asked.add(SetupSlot.maturity);
      return SetupAnswerKind.answered;
  }
}

/// 都齐了（没有要问的）以后的一句：确认 / 算了 / 别的。
SetupAnswerKind answerSetupReady(String raw) {
  final text = normalizeSetupText(raw.trim());
  if (isSetupCancel(text)) return SetupAnswerKind.cancel;
  if (_confirmRe.hasMatch(text)) return SetupAnswerKind.confirm;
  return SetupAnswerKind.notAnswer;
}

String _norm(String s) => s.replaceAll(RegExp(r'[\s，,]'), '');

String? _matchAccount(String text, SetupEnv env, String currency) {
  final accs = env.liquidAccounts.where((a) => a.currency == currency).toList()..sort((a, b) => b.name.length - a.name.length);
  for (final a in accs) {
    if (text.contains(a.name)) return a.id;
  }
  // 「招商」「招行」对「招商银行」
  final bk = bankKeyOf(text);
  if (bk != null) {
    final hits = accs.where((a) => bankKeyOf(a.name) == bk).toList();
    if (hits.length == 1) return hits.single.id;
  }
  return null;
}
