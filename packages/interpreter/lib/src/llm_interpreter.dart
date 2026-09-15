import 'dart:convert';

import 'package:ledger_core/ledger_core.dart';
import 'package:providers/providers.dart';

import 'context.dart';
import 'interpreter.dart';
import 'result.dart';

/// LLM 解析：结构化 JSON 输出，补齐规则填不上的字段。输出仍是候选，一切以 ledger_core 校验为准。
class LLMInterpreter implements Interpreter {
  final ChatProvider provider;
  final Duration timeout;
  LLMInterpreter(this.provider, {this.timeout = const Duration(seconds: 30)});

  @override
  String get name => 'llm';

  @override
  Future<InterpretResult> interpret(String text, InterpretContext ctx) async {
    final r = await provider.complete(system: buildSystemPrompt(ctx), user: text, jsonMode: true, timeout: timeout);
    final json = extractJsonObject(r.text);
    if (json == null) throw ProviderException('interpreter: model did not return JSON: ${r.text}');
    return parseModelJson(json, ctx, modelUsed: r.model);
  }

  static String _offset(int min) {
    final sign = min < 0 ? '-' : '+';
    final a = min.abs();
    return '$sign${(a ~/ 60).toString().padLeft(2, '0')}:${(a % 60).toString().padLeft(2, '0')}';
  }

  static String buildSystemPrompt(InterpretContext ctx) {
    final wall = ctx.wallNow;
    final nowIso = '${wall.toIso8601String().substring(0, 19)}${_offset(ctx.tzOffsetMinutes)}';
    final weekday = ['一', '二', '三', '四', '五', '六', '日'][wall.weekday - 1];
    final accounts = ctx.accounts.map((a) => '- ${a.id}: ${a.name} (${a.currency})').join('\n');
    final expCats = ctx.categories.where((c) => c.kind == 'expense').map((c) => '${c.id}=${c.name}').join(', ');
    final incCats = ctx.categories.where((c) => c.kind == 'income').map((c) => '${c.id}=${c.name}').join(', ');
    final memory = ctx.merchantMap.entries.take(50).map((e) => '- ${e.key} → ${e.value.categoryId ?? ''}${e.value.accountId != null ? ' / ${e.value.accountId}' : ''}').join('\n');
    final recent = ctx.recentTransactions.take(10).map((t) => '- ${t.id}: ${t.localDate} ${Money(t.amountMinor, t.currency)} ${t.categoryId ?? ''} ${t.description ?? ''}').join('\n');
    return '''
你是个人记账助手的解析器。把用户的一句话变成结构化 JSON。只输出一个 JSON 对象，不要任何解释。

当前时间：$nowIso（星期$weekday），时区偏移 ${_offset(ctx.tzOffsetMinutes)}。默认币种 ${ctx.defaultCurrency}。
账户列表（只能用这些 id）：
${accounts.isEmpty ? '(无)' : accounts}
默认账户 id：${ctx.defaultAccountId ?? '(无)'}
支出分类（只能用这些 id）：$expCats
收入分类（只能用这些 id）：$incCats
${memory.isEmpty ? '' : '用户习惯（商户→分类/账户）：\n$memory\n'}${recent.isEmpty ? '' : '最近交易（修改/删除/退款时用于定位）：\n$recent\n'}
输出格式：
{
  "intent": "propose_transactions" | "query" | "propose_update" | "propose_void" | "chat",
  "transactions": [ { "type": "expense|income|transfer|refund", "amount": "28.50", "currency": "CNY",
      "account_id": "...", "to_account_id": "仅 transfer", "category_id": "...", "merchant": "商户名或 null",
      "description": "简短描述", "occurred_at": "2026-09-15T12:30:00+08:00", "refund_of_id": "仅 refund",
      "split": {"total": "86.00", "share": "50.00"} 或省略, "confidence": 0.0-1.0 } ],
  "query": { "metric": "sum|count|avg|max|balance", "type": ["expense"], "time_range": {"from":"yyyy-MM-dd","to":"yyyy-MM-dd"},
      "group_by": "none|category|account|merchant|day|month|currency", "filter": {"category_ids": [], "account_ids": [], "merchant_like": null},
      "compare_to": {"from":"","to":""} 或省略, "limit": 20 },
  "target": { "transaction_id": "最近交易里的 id 或 null", "most_recent": true/false, "amount": "28.00" 或 null, "date": "yyyy-MM-dd" 或 null },
  "patch": { 要修改的字段，同 transactions 里的字段名 },
  "reason": "作废原因"
}

规则：
1. 金额用十进制字符串，正数；方向由 type 决定。"和同事吃饭 86 我付了 50" → amount 50，split.total 86。绝不把总额记成个人支出。
2. 一句话里多笔就输出多条 transactions。
3. 时间必须带时区偏移；"昨晚"=昨天 19:00，"中午"=12:00；没说时间就用当前时间；不确定日期不要编，用当天。
4. 分类和账户只能用给定 id；没把握就填 null，不要猜一个错的。
5. 转账（还信用卡、存钱、充值到钱包）type=transfer，需要 account_id 和 to_account_id，没有分类。
6. 退款 type=refund，尽量在最近交易里找到原单填 refund_of_id。
7. 查询（"花了多少""哪些""对比"）intent=query，只输出 query，不要 transactions。查询不带 time_range 时默认本月。
8. 修改（"改成""记到"）intent=propose_update，给 target 和 patch；删除/作废 intent=propose_void，给 target 和 reason。
9. 与记账无关的话 intent=chat。
''';
  }

  /// 模型 JSON → InterpretResult。做的是格式归一，不做业务校验。
  static InterpretResult parseModelJson(Map<String, Object?> j, InterpretContext ctx, {String? modelUsed, String interpreter = 'llm'}) {
    final intentRaw = (j['intent'] as String?) ?? '';
    final intent = switch (intentRaw) {
      'propose_transactions' => Intent.proposeTransactions,
      'query' => Intent.query,
      'propose_update' => Intent.proposeUpdate,
      'propose_void' => Intent.proposeVoid,
      _ => Intent.chat,
    };
    final notes = <String>[];
    final accountIds = ctx.accounts.map((a) => a.id).toSet();
    final accountByName = {for (final a in ctx.accounts) a.name: a.id};
    final catIds = ctx.categories.map((c) => c.id).toSet();
    final catByName = {for (final c in ctx.categories) c.name: c.id};

    String? accId(Object? v) {
      if (v is! String || v.isEmpty) return null;
      if (accountIds.contains(v)) return v;
      return accountByName[v];
    }

    String? catId(Object? v) {
      if (v is! String || v.isEmpty) return null;
      if (catIds.contains(v)) return v;
      return catByName[v];
    }

    int? minor(Object? v, String currency) {
      if (v == null) return null;
      try {
        if (v is int) return Money.parse(v.toString(), currency).minor;
        if (v is double) return Money.parse(v.toStringAsFixed(Currency.minorUnitOf(currency)), currency).minor;
        if (v is String) return Money.parse(v, currency).minor;
      } catch (e) {
        notes.add('amount unparsable: $v');
      }
      return null;
    }

    String? when(Object? v) {
      if (v is! String || v.isEmpty) return null;
      try {
        return OccurredAt.parse(v, fallbackOffsetMinutes: ctx.tzOffsetMinutes).toIso8601String();
      } catch (_) {
        notes.add('occurred_at unparsable: $v');
        return null;
      }
    }

    final drafts = <DraftCandidate>[];
    if (intent == Intent.proposeTransactions) {
      for (final raw in (j['transactions'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final t = raw.cast<String, Object?>();
        final type = (t['type'] as String?) ?? 'expense';
        final currency = ((t['currency'] as String?) ?? ctx.defaultCurrency).toUpperCase();
        final amount = minor(t['amount_minor'] ?? t['amount'], Currency.isKnown(currency) ? currency : ctx.defaultCurrency);
        final split = t['split'];
        final payload = <String, Object?>{
          'type': type,
          'amount_minor': amount,
          'currency': currency,
          'account_id': accId(t['account_id']) ?? ctx.defaultAccountId,
          if (type == 'transfer') 'to_account_id': accId(t['to_account_id']),
          if (type == 'expense' || type == 'income') 'category_id': catId(t['category_id']),
          if (t['merchant'] is String && (t['merchant'] as String).isNotEmpty) 'merchant': t['merchant'],
          'description': t['description'],
          'occurred_at': when(t['occurred_at']) ?? _nowIso(ctx),
          if (type == 'refund') 'refund_of_id': t['refund_of_id'],
          if (split is Map)
            'metadata': {
              'split': {
                'total': minor(split['total'], currency),
                'share': minor(split['share'], currency),
              }
            },
        };
        final missing = [
          if (amount == null) 'amount_minor',
          if (payload['account_id'] == null) 'account_id',
          if ((type == 'expense' || type == 'income') && payload['category_id'] == null) 'category_id',
        ];
        drafts.add(DraftCandidate(
          payload: payload,
          confidence: ((t['confidence'] as num?)?.toDouble() ?? 0.7).clamp(0, 0.98),
          missing: missing,
        ));
      }
    }

    Map<String, Object?>? query;
    if (intent == Intent.query && j['query'] is Map) {
      query = (j['query'] as Map).cast<String, Object?>();
      final f = query['filter'];
      if (f is Map) {
        final ids = (f['category_ids'] as List? ?? const []).map(catId).whereType<String>().toList();
        final accs = (f['account_ids'] as List? ?? const []).map(accId).whereType<String>().toList();
        query['filter'] = {...f.cast<String, Object?>(), 'category_ids': ids, 'account_ids': accs};
      }
    }

    TargetHint? target;
    Map<String, Object?>? patch;
    if (intent == Intent.proposeUpdate || intent == Intent.proposeVoid) {
      final tj = (j['target'] as Map?)?.cast<String, Object?>() ?? const {};
      final amt = minor(tj['amount'], ctx.defaultCurrency);
      var tid = tj['transaction_id'] as String?;
      if (tid != null && !ctx.recentTransactions.any((t) => t.id == tid)) tid = null;
      if (tid == null) {
        var cands = ctx.recentTransactions.toList();
        if (amt != null) cands = cands.where((t) => t.amountMinor == amt).toList();
        if (tj['date'] is String) cands = cands.where((t) => t.localDate == tj['date']).toList();
        if (cands.isNotEmpty && (amt != null || tj['date'] != null || tj['most_recent'] == true)) tid = cands.first.id;
      }
      target = TargetHint(transactionId: tid, amountMinor: amt, localDate: tj['date'] as String?, mostRecent: tj['most_recent'] == true);
      if (intent == Intent.proposeVoid) {
        patch = {'reason': (j['reason'] as String?) ?? ''};
        if (tid != null) drafts.add(DraftCandidate(payload: {'kind': 'void', 'target_transaction_id': tid, 'reason': patch['reason']}, confidence: 0.7));
      } else {
        final pj = (j['patch'] as Map?)?.cast<String, Object?>() ?? const {};
        patch = {};
        for (final e in pj.entries) {
          switch (e.key) {
            case 'account_id':
            case 'to_account_id':
              patch[e.key] = accId(e.value);
            case 'category_id':
              patch[e.key] = catId(e.value);
            case 'amount':
            case 'amount_minor':
              patch['amount_minor'] = minor(e.value, ctx.defaultCurrency);
            case 'occurred_at':
              patch[e.key] = when(e.value);
            default:
              patch[e.key] = e.value;
          }
        }
        if (tid != null && patch.isNotEmpty) {
          drafts.add(DraftCandidate(payload: {'kind': 'update', 'target_transaction_id': tid, ...patch}, confidence: 0.7));
        }
      }
    }

    return InterpretResult(
      intent: intent,
      drafts: drafts,
      query: query,
      target: target,
      patch: patch,
      interpreter: interpreter,
      modelUsed: modelUsed,
      notes: notes,
    );
  }

  static String _nowIso(InterpretContext ctx) => OccurredAt(ctx.now, ctx.tzOffsetMinutes).toIso8601String();
}

/// 便于日志/测试：把结果压成一行 JSON。
String resultToJson(InterpretResult r) => jsonEncode(r.toJson());
