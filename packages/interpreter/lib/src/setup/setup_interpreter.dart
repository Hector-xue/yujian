import 'package:ledger_core/ledger_core.dart';
import 'package:providers/providers.dart';

import '../context.dart';
import 'setup_numbers.dart';
import 'setup_rule.dart';

/// 对话建档的结果。
class SetupOutcome {
  final List<SetupItem> items;
  final String interpreter; // rule | hybrid
  final String? modelUsed;
  final bool degraded; // 想问模型但模型不可用 / 答得对不上，用的是规则结果
  final List<String> notes;
  const SetupOutcome(this.items, {required this.interpreter, this.modelUsed, this.degraded = false, this.notes = const []});
}

/// 规则先跑；规则认出是在建档、但有数分不清用途时才问模型（配了的话），模型的每个金额都要在原文里找得到，否则不用它。
/// 规则没认出是建档：普通模式直接返回 null（交还记账解析，行为和以前一样）；「登记负债 / 资产」模式下再问一次模型。
///
/// 和记账的 [LLMInterpreter] 分开：它的提示词也给截图 / OCR 识别用，建档的字段不能混进去（不然一张白条账单截图会被当成「建一笔负债」）。
class SetupInterpreter {
  final ChatProvider? llm;
  final Duration timeout;
  SetupInterpreter({this.llm, this.timeout = const Duration(seconds: 30)});

  Future<SetupOutcome?> interpret(String text, InterpretContext ctx, {bool explicit = false, required String today, String Function(String)? redactForModel}) async {
    final rule = parseSetupRule(text, ctx, explicit: explicit, today: today);
    if (rule != null && rule.complete) return SetupOutcome(rule.items, interpreter: 'rule');
    final p = llm;
    if (p == null) {
      if (rule == null) return null;
      return SetupOutcome(rule.items, interpreter: 'rule', degraded: true, notes: ['no model configured', if (rule.unassigned.isNotEmpty) '没分清用途的数：${rule.unassigned.join('、')}']);
    }
    // 普通模式下规则都没认出是建档：不问模型（绝大多数是记账 / 闲聊，别多一次出网）
    if (rule == null && !explicit) return null;
    try {
      final r = await p.complete(system: buildSetupPrompt(ctx, today: today), user: redactForModel == null ? text : redactForModel(text), jsonMode: true, timeout: timeout);
      final j = extractJsonObject(r.text);
      if (j == null) throw ProviderException('setup: model did not return JSON');
      final items = parseSetupModelJson(j, text, ctx, today: today);
      if (items == null) {
        // 模型说不是建档，或金额对不上原文：信规则
        if (rule == null) return null;
        return SetupOutcome(rule.items, interpreter: 'hybrid', modelUsed: r.model, degraded: true, notes: ['model result rejected']);
      }
      if (items.isEmpty) return rule == null ? null : SetupOutcome(rule.items, interpreter: 'hybrid', modelUsed: r.model, notes: const ['model said not a setup']);
      return SetupOutcome(items, interpreter: 'hybrid', modelUsed: r.model);
    } on ProviderException catch (e) {
      if (rule == null) return null;
      return SetupOutcome(rule.items, interpreter: 'rule', degraded: true, notes: ['model unavailable: ${e.message}']);
    } catch (e) {
      if (rule == null) return null;
      return SetupOutcome(rule.items, interpreter: 'rule', degraded: true, notes: ['model error: $e']);
    }
  }

  static String buildSetupPrompt(InterpretContext ctx, {required String today}) {
    final accs = ctx.accounts.map((a) => '- ${a.id}: ${a.name}${a.type == null ? '' : '（${a.type}）'}').join('\n');
    return '''
你是个人记账 App 的「建档」解析器：用户在描述自己**现有的**负债或资产（不是记一笔刚发生的账），把它变成结构化 JSON。只输出一个 JSON 对象，不要解释。

今天：$today。已有账户（只能用这些 id）：
${accs.isEmpty ? '(无)' : accs}

输出格式：
{"is_setup": true/false, "items": [ {
  "kind": "loan|credit|asset|receivable",
  "name": "账户名，如 京东白条 / 房贷 / 工行定期 / 欠小王 / 借给小李",
  "debt_kind": "mortgage|car|online|loan|other（仅 loan）",
  "product": "bank|huabei|baitiao|fenfu|douyin（仅 credit，或由白条/花呗等分期而来的 loan）",
  "principal": "还欠多少 / 有多少钱，十进制字符串，没说就 null",
  "monthly": "每月固定还多少（仅 loan），没说 null",
  "day": 每月几号还（仅 loan，1-31，没说 null）,
  "periods": 还剩几期（仅 loan，没说 null）,
  "from_account_id": "从哪个已有账户还 / 转出，没说 null",
  "limit": "额度（仅 credit），没说 null",
  "due_day": 还款日（仅 credit）, "statement_day": 账单日（仅 credit）,
  "asset_type": "bank|cash|e_wallet|investment（仅 asset；定期/理财/基金/余额宝 = investment）",
  "deposit": true/false（是不是定期存款）, "maturity": "yyyy-MM-dd 或 null", "rate": 年利率百分数或 null,
  "via_action": true/false（说的是「存了 / 转了 / 买了」这种动作，钱可能从已有账户转过去）,
  "currency": "CNY"
} ] }

规则：
1. 只有在描述现状（欠多少、还剩多少、有多少存款、每月还多少）时 is_setup 才是 true；「还了白条 1000」「借给小李 3000」「午饭 28」是记账，is_setup=false。问句也是 false。
2. 白条 / 花呗 / 分付 / 月付 / 信用卡：说了每月固定还多少（分期）→ kind=loan 且 product 填对应产品；没说固定月供 → kind=credit。
3. 金额必须是原文里出现过的数（「五千」= 5000，「1万2」= 12000，「1.5万」= 15000），不要自己算、不要编。没说的字段一律 null。
4. 一句话里说了几件就输出几项。''';
  }
}

/// 解析模型的 JSON。返回 null = 不采用（金额对不上原文 / 结构不对）；空列表 = 模型说不是建档。
List<SetupItem>? parseSetupModelJson(Map<String, Object?> j, String text, InterpretContext ctx, {required String today}) {
  if (j['is_setup'] != true) return const [];
  final raw = j['items'];
  if (raw is! List || raw.isEmpty) return const [];
  final textMoney = extractSetupNumbers(text).where((n) => n.kind == NumKind.money).map((n) => n.value).toSet();
  final ids = {for (final a in ctx.accounts) a.id};
  int? money(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    if (s.isEmpty || s == 'null') return null;
    try {
      final m = Money.parse(s, 'CNY').minor;
      return m;
    } catch (_) {
      return -1; // 解析不了 = 不采用
    }
  }

  int? intOf(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  final out = <SetupItem>[];
  for (final e in raw) {
    if (e is! Map) return null;
    final m = e.cast<String, Object?>();
    final kind = SetupKind.values.asNameMap()[m['kind']];
    final name = '${m['name'] ?? ''}'.trim();
    if (kind == null || name.isEmpty || name.length > 40) return null;
    final principal = money(m['principal']);
    final monthly = money(m['monthly']);
    final limit = money(m['limit']);
    for (final v in [principal, monthly, limit]) {
      if (v == null) continue;
      if (v < 0 || !textMoney.contains(v)) return null; // 原文里没有这个数：模型编的 / 算的，不采用
    }
    final currency = '${m['currency'] ?? 'CNY'}';
    final from = m['from_account_id'] as String?;
    final it = SetupItem(
      kind: kind,
      name: name,
      currency: Currency.isKnown(currency) ? currency : 'CNY',
      principalMinor: principal,
      debtKind: DebtKind.values.asNameMap()[m['debt_kind']] ?? DebtKind.other,
      monthlyMinor: kind == SetupKind.loan ? monthly : null,
      day: kind == SetupKind.loan ? _day(intOf(m['day'])) : null,
      periods: kind == SetupKind.loan ? intOf(m['periods']) : null,
      fromAccountId: from != null && ids.contains(from) ? from : null,
      product: CreditProductX.of(m['product'] as String?),
      limitMinor: kind == SetupKind.credit ? limit : null,
      dueDay: kind == SetupKind.credit ? _day(intOf(m['due_day'])) : null,
      statementDay: kind == SetupKind.credit ? _day(intOf(m['statement_day'])) : null,
      assetType: switch (m['asset_type']) { 'cash' => AccountType.cash, 'e_wallet' => AccountType.eWallet, 'investment' => AccountType.investment, _ => AccountType.bank },
      deposit: kind == SetupKind.asset && m['deposit'] == true,
      maturity: _date(m['maturity']),
      ratePercent: (m['rate'] is num && (m['rate'] as num) > 0 && (m['rate'] as num) < 30) ? (m['rate'] as num).toDouble() : null,
      viaAction: kind == SetupKind.asset && m['via_action'] == true,
    );
    if (it.deposit) it.assetType = AccountType.investment;
    if (it.kind == SetupKind.credit) {
      if (it.dueDay != null && it.dueDay! > 28) it.dueDay = 28;
      if (it.statementDay != null && it.statementDay! > 28) it.statementDay = 28;
    }
    if (it.kind == SetupKind.asset && it.viaAction && it.fromAccountId != null) it.fromTransfer = true;
    if (it.kind == SetupKind.loan && (it.day ?? 0) > 28) it.notes.add('${it.day} 号按 28 号建（周期最多到 28 号）');
    it.existingAccountId = findExistingAccount(it, ctx);
    out.add(it);
  }
  // 资产的动作句碰上已有账户：交还记账
  out.removeWhere((it) => it.existingAccountId != null && it.viaAction);
  return out;
}

int? _day(int? d) => d == null || d < 1 || d > 31 ? null : d;

String? _date(Object? v) {
  final s = '${v ?? ''}';
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) ? s : null;
}
