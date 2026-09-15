import 'dart:convert';
import 'dart:io';

import 'package:interpreter/interpreter.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:providers/providers.dart';
import 'package:query_dsl/query_dsl.dart';

/// Phase 0 验收用命令行：一句话 → 草稿 → 确认落账 → 查询。
/// dart run packages/interpreter/bin/yujian_cli.dart [--db yujian.db] [--tz 480]
/// 设置 YUJIAN_LLM_BASE_URL / YUJIAN_LLM_API_KEY / YUJIAN_LLM_MODEL 则启用混合解析，否则纯规则。
Future<void> main(List<String> args) async {
  var dbPath = 'yujian.db';
  var tz = DateTime.now().timeZoneOffset.inMinutes;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--db') dbPath = args[++i];
    if (args[i] == '--tz') tz = int.parse(args[++i]);
  }
  final db = dbPath == ':memory:' ? LedgerDatabase.inMemory() : LedgerDatabase.open(dbPath);
  final ledger = Ledger(db)..seedDefaultCategories();
  if (ledger.listAccounts().isEmpty) {
    ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    ledger.createAccount(id: 'alipay', name: '支付宝', type: AccountType.eWallet, currency: 'CNY');
    ledger.createAccount(id: 'cash', name: '现金', type: AccountType.cash, currency: 'CNY');
  }
  final cfg = ProviderConfig.fromEnvironment(Platform.environment);
  final interp = HybridInterpreter(llm: cfg == null ? null : LLMInterpreter(OpenAICompatProvider(cfg)));
  final engine = QueryEngine(ledger);

  stdout.writeln('余见 · 账本 $dbPath · 解析 ${cfg == null ? '规则（未配置模型）' : '规则+${cfg.model}'}');
  stdout.writeln('直接输入一句话记账/查询；:inbox :list :balance :audit :quit');

  List<Draft> pending = [];
  while (true) {
    stdout.write('\n> ');
    final line = stdin.readLineSync(encoding: utf8)?.trim();
    if (line == null || line == ':quit' || line == ':q') break;
    if (line.isEmpty) continue;

    if (line == ':balance') {
      for (final e in ledger.balances().entries) {
        stdout.writeln('  ${ledger.getAccount(e.key).name.padRight(8)} ${e.value}');
      }
      continue;
    }
    if (line == ':list') {
      for (final t in ledger.listTransactions(limit: 20)) {
        stdout.writeln('  ${t.id.substring(18)} ${t.occurredAt.localDate} ${t.type.db.padRight(8)} ${Money(t.amountMinor, t.currency).toString().padLeft(12)} ${t.categoryId ?? '-'} ${t.description ?? ''}');
      }
      continue;
    }
    if (line == ':inbox') {
      pending = ledger.listDrafts(status: DraftStatus.pending);
      _printDrafts(pending, ledger);
      continue;
    }
    if (line == ':audit') {
      for (final e in ledger.auditLog(limit: 15)) {
        stdout.writeln('  ${e.at.toIso8601String().substring(0, 19)} ${e.actor.db.padRight(11)} ${e.action.padRight(18)} ${e.targetId.substring(18)}${e.confirmedByUser ? ' ✓' : ''}');
      }
      continue;
    }
    if (line == 'y' || line == 'ok' || line == '确认') {
      if (pending.isEmpty) {
        stdout.writeln('  没有待确认的草稿');
        continue;
      }
      for (final d in pending) {
        try {
          final tx = ledger.commit(d.id);
          stdout.writeln('  ✓ 已记账 ${tx.id.substring(18)} ${tx.type.db} ${Money(tx.amountMinor, tx.currency)} ${tx.categoryId ?? ''} ${tx.description ?? ''}');
        } on LedgerException catch (e) {
          stdout.writeln('  ✗ ${d.id.substring(18)} $e');
        }
      }
      pending = [];
      continue;
    }
    if (line == 'n' || line == 'no' || line == '取消') {
      for (final d in pending) {
        ledger.dismiss(d.id);
      }
      stdout.writeln('  已忽略 ${pending.length} 条');
      pending = [];
      continue;
    }

    final ctx = _context(ledger, tz);
    final sw = Stopwatch()..start();
    final r = await interp.interpret(line, ctx);
    final ms = sw.elapsedMilliseconds;
    switch (r.intent) {
      case Intent.query:
        try {
          final q = QueryDsl.fromJson(r.query!);
          final res = engine.run(q);
          stdout.writeln('  [${r.interpreter}${r.modelUsed != null ? '/${r.modelUsed}' : ''} ${ms}ms] ${jsonEncode(q.toJson())}');
          for (final row in res.rows) {
            final v = q.metric == Metric.count ? '${row.valueMinor} 笔' : Money(row.valueMinor, row.currency).toString();
            stdout.writeln('  ${row.label.padRight(8)} ${v.padLeft(14)}  (${row.count} 笔)');
          }
          if (res.compareRows != null) {
            stdout.writeln('  对比期：');
            for (final row in res.compareRows!) {
              stdout.writeln('  ${row.label.padRight(8)} ${Money(row.valueMinor, row.currency).toString().padLeft(14)}  (${row.count} 笔)');
            }
          }
          if (res.rows.isEmpty) stdout.writeln('  （没有匹配的交易）');
        } on FormatException catch (e) {
          stdout.writeln('  查询无法执行：$e');
        }
      case Intent.chat:
        stdout.writeln('  [${r.interpreter} ${ms}ms] 没识别出记账或查询意图${r.degraded ? '（模型不可用）' : ''}');
      case Intent.proposeTransactions:
      case Intent.proposeUpdate:
      case Intent.proposeVoid:
        final inputs = <DraftInput>[];
        for (final d in r.drafts) {
          final kind = d.payload['kind'];
          if (kind == 'update') {
            final patch = {...d.payload}..remove('kind')..remove('target_transaction_id');
            inputs.add(DraftInput(kind: DraftKind.update, targetTransactionId: d.payload['target_transaction_id'] as String, payload: patch, confidence: d.confidence));
          } else if (kind == 'void') {
            inputs.add(DraftInput(kind: DraftKind.void_, targetTransactionId: d.payload['target_transaction_id'] as String, payload: {'reason': d.payload['reason']}, confidence: d.confidence));
          } else {
            inputs.add(DraftInput(payload: d.payload, confidence: d.confidence));
          }
        }
        if (inputs.isEmpty) {
          stdout.writeln('  [${r.interpreter} ${ms}ms] 识别为 ${r.intent.name}，但没定位到目标：${r.notes.join('; ')}');
          continue;
        }
        pending = ledger.propose(inputs, source: Source.chat, interpreter: r.interpreter, modelUsed: r.modelUsed);
        stdout.writeln('  [${r.interpreter}${r.modelUsed != null ? '/${r.modelUsed}' : ''} ${ms}ms${r.degraded ? ' 模型不可用，规则结果' : ''}]');
        _printDrafts(pending, ledger);
        stdout.writeln('  输入 y 确认 / n 取消');
    }
  }
  db.close();
}

void _printDrafts(List<Draft> ds, Ledger ledger) {
  if (ds.isEmpty) {
    stdout.writeln('  收件箱为空');
    return;
  }
  for (final d in ds) {
    final p = d.payload;
    final desc = switch (d.kind) {
      DraftKind.create => '${p['type']} ${Money((p['amount_minor'] as int?) ?? 0, (p['currency'] as String?) ?? 'CNY')} '
          '${p['category_id'] != null ? ledger.category(p['category_id'] as String)?.name ?? p['category_id'] : '-'} '
          '${p['account_id'] != null ? ledger.account(p['account_id'] as String)?.name ?? p['account_id'] : '?'}'
          '${p['to_account_id'] != null ? ' → ${ledger.account(p['to_account_id'] as String)?.name}' : ''} '
          '${(p['occurred_at'] as String?)?.substring(0, 16) ?? ''} ${p['description'] ?? ''}',
      DraftKind.update => 'update ${(d.targetTransactionId ?? '').substring(18)} ${jsonEncode(p)}',
      DraftKind.void_ => 'void ${(d.targetTransactionId ?? '').substring(18)} ${p['reason']}',
    };
    final flags = [
      if (d.missingFields.isNotEmpty) '缺: ${d.missingFields.join(',')}',
      if (d.possibleDuplicateOf != null) '疑似重复',
      if (d.confidence != null) '置信 ${(d.confidence! * 100).round()}%',
    ];
    stdout.writeln('  ${d.id.substring(18)} $desc${flags.isEmpty ? '' : '  [${flags.join(' | ')}]'}');
  }
}

InterpretContext _context(Ledger ledger, int tz) {
  final accounts = ledger.listAccounts();
  return InterpretContext(
    now: DateTime.now(),
    tzOffsetMinutes: tz,
    defaultAccountId: accounts.isEmpty ? null : accounts.first.id,
    accounts: [for (final a in accounts) AccountRef(id: a.id, name: a.name, currency: a.currency)],
    categories: [for (final c in ledger.listCategories()) CategoryRef(id: c.id, name: c.name, kind: c.kind.db, parentId: c.parentId)],
    recentTransactions: [
      for (final t in ledger.listTransactions(limit: 20))
        RecentTransaction(id: t.id, amountMinor: t.amountMinor, currency: t.currency, localDate: t.occurredAt.localDate, categoryId: t.categoryId, description: t.description),
    ],
  );
}
