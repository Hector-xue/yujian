import 'dart:convert';

import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

void main() {
  late Ledger ledger;
  late McpServer server;
  var nextId = 1;

  Map<String, Object?> rpc(String method, [Map<String, Object?>? params]) =>
      server.handle({'jsonrpc': '2.0', 'id': nextId++, 'method': method, if (params != null) 'params': params})!;

  Object? callTool(String name, [Map<String, Object?> args = const {}]) {
    final r = rpc('tools/call', {'name': name, 'arguments': args});
    final res = r['result'] as Map;
    final text = ((res['content'] as List).first as Map)['text'] as String;
    if (res['isError'] == true) throw StateError(text);
    return jsonDecode(text);
  }

  setUp(() {
    ledger = Ledger(openLedgerDatabaseInMemory(), clock: () => DateTime.utc(2026, 9, 15, 4))..seedDefaultCategories();
    ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY', initialBalanceMinor: 10000);
    ledger.commit(ledger.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'description': '午饭', 'occurred_at': '2026-09-15T12:00:00+08:00'})], source: Source.manual).single.id);
    server = McpServer(ledger, today: () => '2026-09-15');
  });

  test('initialize and tools/list expose only read + propose tools', () {
    final init = rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '0'}});
    expect((init['result'] as Map)['protocolVersion'], mcpProtocolVersion);
    expect(server.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), isNull);
    final names = ((rpc('tools/list')['result'] as Map)['tools'] as List).map((t) => (t as Map)['name']).toSet();
    expect(names, containsAll(['query_ledger', 'list_accounts', 'propose_transactions', 'propose_update', 'propose_void', 'list_inbox']));
    expect(names.where((n) => n.toString().startsWith('create') || n.toString().startsWith('delete') || n.toString().startsWith('commit')), isEmpty);
  });

  test('read tools', () {
    final accs = callTool('list_accounts') as List;
    expect((accs.single as Map)['balance'], '72.00');
    final q = callTool('query_ledger', {'metric': 'sum', 'time_range': {'from': '2026-09-01', 'to': '2026-09-30'}}) as Map;
    expect(((q['rows'] as List).single as Map)['value'], '28.00');
    final txs = callTool('list_transactions', {'from': '2026-09-15', 'to': '2026-09-15'}) as List;
    expect((txs.single as Map)['amount'], '28.00');
    expect((txs.single as Map)['category'], '餐饮');
    expect(callTool('list_transactions', {'from': '2026-09-16', 'to': '2026-09-30'}), isEmpty);
    expect(callTool('get_budget_status'), isEmpty);
  });

  test('propose_transactions lands in inbox, never commits; amount as decimal string', () {
    final r = callTool('propose_transactions', {
      'items': [
        {'type': 'expense', 'amount': '36.50', 'account_id': 'wechat', 'category_id': 'transport', 'description': '打车', 'occurred_at': '2026-09-15T20:00:00+08:00'},
        {'type': 'expense', 'amount': '9.90'},
      ],
      'note': 'claude-desktop',
    }) as Map;
    final drafts = r['drafts'] as List;
    expect(drafts.length, 2);
    expect((drafts[0] as Map)['missing_fields'], isEmpty);
    expect(((drafts[0] as Map)['payload'] as Map)['amount_minor'], 3650);
    expect((drafts[1] as Map)['missing_fields'], containsAll(['account_id', 'category_id', 'occurred_at']));
    expect(ledger.listTransactions().length, 1); // 没入账
    expect(ledger.listDrafts(status: DraftStatus.pending).length, 2);
    expect(ledger.listDrafts(status: DraftStatus.pending).first.source, Source.mcp);
    expect((callTool('list_inbox') as List).length, 2);
  });

  test('propose_update / propose_void resolve targets; errors are isError not exceptions', () {
    final tx = ledger.listTransactions().single;
    final u = callTool('propose_update', {'target_id': tx.id, 'patch': {'category_id': 'transport'}}) as Map;
    expect(((u['draft'] as Map)['payload'] as Map)['category_id'], 'transport');
    final v = callTool('propose_void', {'target_id': tx.id, 'reason': 'dup'}) as Map;
    expect((v['draft'] as Map)['kind'], 'void');
    expect(ledger.listTransactions().single.status, TransactionStatus.confirmed);
    expect(() => callTool('get_transaction', {'id': 'nope'}), throwsStateError);
    expect(() => callTool('propose_transactions', {'items': []}), throwsStateError);
    final unknown = rpc('nope/method');
    expect((unknown['error'] as Map)['code'], -32601);
  });
}
