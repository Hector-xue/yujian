import 'dart:convert';
import 'dart:io';

import 'package:ledger_core/ledger_core.dart';

import 'context.dart';
import 'result.dart';

/// 语料集加载与逐字段判分。规则/LLM/混合三路共用同一把尺子。
class Corpus {
  final InterpretContext context;
  final List<CorpusCase> cases;
  const Corpus(this.context, this.cases);

  static Corpus load(String path) => fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>);

  static Corpus fromJson(Map<String, Object?> j) {
    final now = OccurredAt.parse(j['now'] as String);
    final categories = [
      for (final c in defaultCategories) CategoryRef(id: c.id, name: c.name, kind: c.kind.db, parentId: c.parentId),
    ];
    final ctx = InterpretContext(
      now: now.utc,
      tzOffsetMinutes: (j['tz_offset_minutes'] as num?)?.toInt() ?? now.offsetMinutes,
      defaultCurrency: (j['default_currency'] as String?) ?? 'CNY',
      defaultAccountId: j['default_account'] as String?,
      accounts: [
        for (final a in (j['accounts'] as List).cast<Map>())
          AccountRef(id: a['id'] as String, name: a['name'] as String, currency: a['currency'] as String, aliases: ((a['aliases'] as List?) ?? const []).cast<String>()),
      ],
      categories: categories,
      merchantMap: {
        for (final e in ((j['memory'] as Map?) ?? const {}).entries)
          e.key as String: (categoryId: (e.value as Map)['category_id'] as String?, accountId: (e.value as Map)['account_id'] as String?),
      },
      recentTransactions: [
        for (final t in ((j['recent'] as List?) ?? const []).cast<Map>())
          RecentTransaction(
            id: t['id'] as String,
            amountMinor: (t['amount_minor'] as num).toInt(),
            currency: t['currency'] as String,
            localDate: t['local_date'] as String,
            categoryId: t['category_id'] as String?,
            description: t['description'] as String?,
          ),
      ],
    );
    final cases = [
      for (final c in (j['cases'] as List).cast<Map>())
        CorpusCase(id: c['id'] as String, tag: (c['tag'] as String?) ?? '', text: c['text'] as String, expect: (c['expect'] as Map).cast<String, Object?>()),
    ];
    return Corpus(ctx, cases);
  }
}

class CorpusCase {
  final String id;
  final String tag;
  final String text;
  final Map<String, Object?> expect;
  const CorpusCase({required this.id, required this.tag, required this.text, required this.expect});
}

/// 一条用例的判分明细。
class CaseScore {
  final String id;
  final bool intentOk;
  /// 每笔期望草稿的逐字段命中（键：amount/type/date/category/account/...）；null 表示该字段未被期望。
  final List<Map<String, bool?>> drafts;
  final List<String> failures;
  const CaseScore({required this.id, required this.intentOk, required this.drafts, required this.failures});
  bool get pass => failures.isEmpty;
}

CaseScore scoreCase(CorpusCase c, InterpretResult r) {
  final failures = <String>[];
  final expectIntent = c.expect['intent'] as String;
  final gotIntent = switch (r.intent) {
    Intent.proposeTransactions => 'propose_transactions',
    Intent.query => 'query',
    Intent.proposeUpdate => 'propose_update',
    Intent.proposeVoid => 'propose_void',
    Intent.chat => 'chat',
  };
  final intentOk = gotIntent == expectIntent;
  if (!intentOk) failures.add('intent: want $expectIntent got $gotIntent');
  final draftScores = <Map<String, bool?>>[];

  final expDrafts = (c.expect['drafts'] as List?)?.cast<Map>() ?? const [];
  if (expDrafts.isNotEmpty) {
    if (r.drafts.length != expDrafts.length) failures.add('draft count: want ${expDrafts.length} got ${r.drafts.length}');
    for (var i = 0; i < expDrafts.length; i++) {
      final e = expDrafts[i].cast<String, Object?>();
      final g = i < r.drafts.length ? r.drafts[i].payload : const <String, Object?>{};
      final s = <String, bool?>{};
      bool eq(String key, Object? want, Object? got) {
        final ok = want == got;
        if (!ok) failures.add('draft[$i].$key: want $want got $got');
        return ok;
      }

      s['amount'] = eq('amount_minor', (e['amount_minor'] as num).toInt(), g['amount_minor']);
      s['type'] = eq('type', e['type'], g['type']);
      s['currency'] = e.containsKey('currency') ? eq('currency', e['currency'], g['currency']) : null;
      s['category'] = e.containsKey('category_id') ? eq('category_id', e['category_id'], g['category_id']) : null;
      s['account'] = e.containsKey('account_id') ? eq('account_id', e['account_id'], g['account_id']) : null;
      s['to_account'] = e.containsKey('to_account_id') ? eq('to_account_id', e['to_account_id'], g['to_account_id']) : null;
      s['merchant'] = e.containsKey('merchant') ? eq('merchant', e['merchant'], g['merchant']) : null;
      s['refund_of'] = e.containsKey('refund_of_id') ? eq('refund_of_id', e['refund_of_id'], g['refund_of_id']) : null;
      final occ = g['occurred_at'] is String ? OccurredAt.parse(g['occurred_at'] as String) : null;
      s['date'] = e.containsKey('date') ? eq('date', e['date'], occ?.localDate) : null;
      if (e.containsKey('time')) {
        final w = occ?.wall;
        final hm = w == null ? null : '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
        s['time'] = eq('time', e['time'], hm);
      }
      if (e.containsKey('split_total')) {
        final split = (g['metadata'] as Map?)?['split'] as Map?;
        s['split'] = eq('split_total', (e['split_total'] as num).toInt(), split?['total']);
      }
      draftScores.add(s);
    }
  }

  final expQuery = (c.expect['query'] as Map?)?.cast<String, Object?>();
  if (expQuery != null) {
    final q = r.query ?? const <String, Object?>{};
    if (expQuery.containsKey('metric') && q['metric'] != expQuery['metric']) failures.add('query.metric: want ${expQuery['metric']} got ${q['metric']}');
    if (expQuery.containsKey('group_by') && q['group_by'] != expQuery['group_by']) failures.add('query.group_by: want ${expQuery['group_by']} got ${q['group_by']}');
    if (expQuery.containsKey('time_range')) {
      final tr = (q['time_range'] as Map?) ?? const {};
      final want = expQuery['time_range'] as Map;
      if (tr['from'] != want['from'] || tr['to'] != want['to']) failures.add('query.time_range: want ${want['from']}..${want['to']} got ${tr['from']}..${tr['to']}');
    }
    if (expQuery.containsKey('category_ids')) {
      final got = ((q['filter'] as Map?)?['category_ids'] as List?)?.cast<String>() ?? const [];
      final want = (expQuery['category_ids'] as List).cast<String>();
      if (got.join(',') != want.join(',')) failures.add('query.category_ids: want $want got $got');
    }
    if (expQuery['has_compare'] == true && q['compare_to'] == null) failures.add('query.compare_to missing');
  }

  if (c.expect.containsKey('target_id')) {
    final got = r.target?.transactionId;
    if (got != c.expect['target_id']) failures.add('target: want ${c.expect['target_id']} got $got');
  }
  final expPatch = (c.expect['patch'] as Map?)?.cast<String, Object?>();
  if (expPatch != null) {
    for (final e in expPatch.entries) {
      if (r.patch?[e.key] != e.value) failures.add('patch.${e.key}: want ${e.value} got ${r.patch?[e.key]}');
    }
  }
  return CaseScore(id: c.id, intentOk: intentOk, drafts: draftScores, failures: failures);
}

/// 汇总指标（§15.2）。
class CorpusMetrics {
  int cases = 0, passed = 0, intentOk = 0;
  final hit = <String, int>{};
  final total = <String, int>{};

  void add(CaseScore s) {
    cases++;
    if (s.pass) passed++;
    if (s.intentOk) intentOk++;
    for (final d in s.drafts) {
      for (final e in d.entries) {
        if (e.value == null) continue;
        total[e.key] = (total[e.key] ?? 0) + 1;
        if (e.value == true) hit[e.key] = (hit[e.key] ?? 0) + 1;
      }
    }
  }

  String pct(String k) => total[k] == null || total[k] == 0 ? '  n/a' : '${(100 * (hit[k] ?? 0) / total[k]!).toStringAsFixed(1)}%';

  Map<String, Object?> toJson() => {
        'cases': cases,
        'passed': passed,
        'intent_acc': cases == 0 ? null : intentOk / cases,
        for (final k in total.keys) '${k}_acc': (hit[k] ?? 0) / total[k]!,
      };
}
