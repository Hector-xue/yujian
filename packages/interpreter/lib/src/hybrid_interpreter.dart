import 'package:providers/providers.dart';

import 'context.dart';
import 'interpreter.dart';
import 'llm_interpreter.dart';
import 'result.dart';
import 'rule/amount.dart';
import 'rule/rule_interpreter.dart';

/// 默认编排（§7.1）：规则先跑；完整且高置信直接用；否则交给 LLM 补齐；
/// LLM 不可用就退回规则结果并标 degraded。LLM 的金额与文本里的数字交叉核对，不一致降置信。
class HybridInterpreter implements Interpreter {
  final RuleInterpreter rule;
  final LLMInterpreter? llm;
  final double ruleConfidenceThreshold;

  HybridInterpreter({RuleInterpreter? rule, this.llm, this.ruleConfidenceThreshold = 0.8}) : rule = rule ?? RuleInterpreter();

  @override
  String get name => 'hybrid';

  @override
  Future<InterpretResult> interpret(String text, InterpretContext ctx, {String Function(String)? redactForModel}) async {
    final r = rule.interpretSync(text, ctx);
    if (llm == null) return _asHybrid(r, degraded: true, note: 'no model configured');
    if (_ruleIsEnough(r)) return _asHybrid(r);

    final InterpretResult l;
    try {
      l = await llm!.interpret(redactForModel == null ? text : redactForModel(text), ctx);
    } on ProviderException catch (e) {
      return _asHybrid(r, degraded: true, note: 'model unavailable: ${e.message}');
    } catch (e) {
      return _asHybrid(r, degraded: true, note: 'model error: $e');
    }
    return _merge(text, r, l, ctx);
  }

  bool _ruleIsEnough(InterpretResult r) {
    switch (r.intent) {
      case Intent.proposeTransactions:
        return r.drafts.isNotEmpty && r.drafts.every((d) => d.missing.isEmpty && d.confidence >= ruleConfidenceThreshold);
      case Intent.query:
        return true; // 规则查询是确定性的；LLM 只在规则完全认不出查询意图时才会被用到
      case Intent.proposeUpdate:
      case Intent.proposeVoid:
        return r.drafts.isNotEmpty;
      case Intent.chat:
        return false;
    }
  }

  InterpretResult _merge(String text, InterpretResult r, InterpretResult l, InterpretContext ctx) {
    final notes = <String>[...l.notes];
    var drafts = l.drafts;
    if (l.intent == Intent.proposeTransactions) {
      final textAmounts = extractAmounts(text, defaultCurrency: ctx.defaultCurrency).map((h) => h.minor).toSet();
      final llmAmounts = drafts.map((d) => d.payload['amount_minor']).whereType<int>().toSet();
      if (textAmounts.isNotEmpty && !llmAmounts.every(textAmounts.contains)) {
        notes.add('amount cross-check failed: text=$textAmounts model=$llmAmounts');
        drafts = drafts.map((d) => DraftCandidate(payload: d.payload, confidence: d.confidence * 0.6, missing: d.missing, notes: [...d.notes, 'amount not found in text'])).toList();
      }
      // 规则识别的账户/分类可以补 LLM 留空的字段（规则只在有把握时才填）
      if (r.intent == Intent.proposeTransactions && r.drafts.length == drafts.length) {
        drafts = [
          for (var i = 0; i < drafts.length; i++)
            DraftCandidate(
              payload: {
                ...drafts[i].payload,
                if (drafts[i].payload['account_id'] == null && r.drafts[i].payload['account_id'] != null) 'account_id': r.drafts[i].payload['account_id'],
                if (drafts[i].payload['category_id'] == null && r.drafts[i].payload['category_id'] != null) 'category_id': r.drafts[i].payload['category_id'],
              },
              confidence: drafts[i].confidence,
              missing: drafts[i].missing.where((m) => !((m == 'account_id' && r.drafts[i].payload['account_id'] != null) || (m == 'category_id' && r.drafts[i].payload['category_id'] != null))).toList(),
              notes: drafts[i].notes,
            ),
        ];
      }
    }
    // LLM 说是闲聊但规则抓到了金额：信规则（宁可多问一次确认，不丢一笔账）
    if (l.intent == Intent.chat && r.intent == Intent.proposeTransactions) {
      return _asHybrid(r, note: 'model said chat, rule found amounts');
    }
    return InterpretResult(
      intent: l.intent,
      drafts: drafts,
      query: l.query,
      target: l.target,
      patch: l.patch,
      interpreter: 'hybrid',
      modelUsed: l.modelUsed,
      notes: notes,
    );
  }

  InterpretResult _asHybrid(InterpretResult r, {bool degraded = false, String? note}) => InterpretResult(
        intent: r.intent,
        drafts: r.drafts,
        query: r.query,
        target: r.target,
        patch: r.patch,
        interpreter: 'hybrid',
        modelUsed: null,
        degraded: degraded,
        notes: [...r.notes, if (note != null) note],
      );
}
