import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

class ToolDef {
  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  const ToolDef(this.name, this.description, this.inputSchema);
  Map<String, Object?> toJson() => {'name': name, 'description': description, 'inputSchema': inputSchema};
}

const _txItem = <String, Object?>{
  'type': 'object',
  'properties': {
    'type': {'type': 'string', 'enum': ['expense', 'income', 'transfer', 'refund']},
    'amount': {'type': 'string', 'description': '十进制字符串，如 "28.50"'},
    'currency': {'type': 'string', 'default': 'CNY'},
    'account_id': {'type': 'string'},
    'to_account_id': {'type': 'string', 'description': '仅 transfer'},
    'category_id': {'type': 'string'},
    'merchant': {'type': 'string'},
    'description': {'type': 'string'},
    'occurred_at': {'type': 'string', 'description': 'ISO-8601 带时区偏移'},
    'refund_of_id': {'type': 'string', 'description': '仅 refund'},
  },
  'required': ['type', 'amount'],
};

final toolDefs = <ToolDef>[
  const ToolDef('list_accounts', '列出账户与当前余额', {'type': 'object', 'properties': {}}),
  const ToolDef('list_categories', '列出分类（支出/收入）', {'type': 'object', 'properties': {'kind': {'type': 'string', 'enum': ['expense', 'income']}}}),
  const ToolDef('list_transactions', '按时间范围列交易', {
    'type': 'object',
    'properties': {'from': {'type': 'string', 'description': 'yyyy-MM-dd'}, 'to': {'type': 'string'}, 'limit': {'type': 'integer', 'default': 50}},
  }),
  const ToolDef('get_transaction', '取一笔交易', {'type': 'object', 'properties': {'id': {'type': 'string'}}, 'required': ['id']}),
  const ToolDef('query_ledger', '用 Query DSL 聚合查询（sum/count/avg/max/balance，可分组、对比期）。结果带依据交易 id。', {
    'type': 'object',
    'properties': {
      'metric': {'type': 'string', 'enum': ['sum', 'count', 'avg', 'max', 'balance', 'forecast']},
      'type': {'type': 'array', 'items': {'type': 'string'}},
      'time_range': {'type': 'object', 'properties': {'from': {'type': 'string'}, 'to': {'type': 'string'}}},
      'group_by': {'type': 'string', 'enum': ['none', 'category', 'account', 'merchant', 'day', 'month', 'currency']},
      'filter': {'type': 'object'},
      'compare_to': {'type': 'object'},
      'limit': {'type': 'integer'},
    },
  }),
  const ToolDef('detect_anomalies', '找出明显高于平时的支出（同分类 90 天基线，3×中位数或均值+2σ）', {
    'type': 'object',
    'properties': {'from': {'type': 'string', 'description': 'yyyy-MM-dd'}, 'to': {'type': 'string'}},
    'required': ['from', 'to'],
  }),
  const ToolDef('get_budget_status', '各预算当前周期执行情况', {'type': 'object', 'properties': {'today': {'type': 'string', 'description': 'yyyy-MM-dd，默认今天'}}}),
  const ToolDef('list_recurring', '周期账单及下次到期', {'type': 'object', 'properties': {}}),
  const ToolDef('list_inbox', '收件箱里待确认的草稿', {'type': 'object', 'properties': {}}),
  const ToolDef('propose_transactions', '提议若干笔交易。只进收件箱，用户在 App 里确认后才入账；返回草稿 id 与缺失字段。', {
    'type': 'object',
    'properties': {'items': {'type': 'array', 'items': _txItem}, 'note': {'type': 'string', 'description': '来源说明，写进审计'}},
    'required': ['items'],
  }),
  const ToolDef('propose_update', '提议修改一笔交易（patch 字段同 propose_transactions 的条目）。进收件箱。', {
    'type': 'object',
    'properties': {'target_id': {'type': 'string'}, 'patch': {'type': 'object'}},
    'required': ['target_id', 'patch'],
  }),
  const ToolDef('list_goals', '目标（心愿 / 应急金 / 还清 / 里程碑）及进度：已攒、目标额、按当前速度还要几天', {'type': 'object', 'properties': {'today': {'type': 'string', 'description': 'yyyy-MM-dd，默认今天'}}}),
  const ToolDef('get_wealth', '财富指标：可花的（可支配余额）、今天还能花、生存月数与等级、储蓄率、净资产、收入分线；每个数都是账本推导的', {'type': 'object', 'properties': {'today': {'type': 'string'}}}),
  const ToolDef('list_tasks', '周任务（本周及最近几周）与结算结果', {'type': 'object', 'properties': {'week': {'type': 'string', 'description': '那一周周一 yyyy-MM-dd，默认本周'}}}),
  const ToolDef('propose_goal', '提议建一个目标。只写进收件箱式的「待建目标」列表（返回草案），不会直接创建；用户在余见的目标页确认。', {
    'type': 'object',
    'properties': {'kind': {'type': 'string', 'enum': ['wish', 'emergency', 'milestone']}, 'name': {'type': 'string'}, 'amount': {'type': 'string', 'description': '目标金额，元'}, 'deadline': {'type': 'string', 'description': 'yyyy-MM-dd'}, 'emoji': {'type': 'string'}},
    'required': ['kind', 'name', 'amount'],
  }),
  const ToolDef('propose_deposit', '提议往某个目标存一笔（一笔转账草稿进收件箱，用户确认后才记账）', {
    'type': 'object',
    'properties': {'goal_id': {'type': 'string'}, 'amount': {'type': 'string', 'description': '元'}, 'from_account_id': {'type': 'string'}},
    'required': ['goal_id', 'amount'],
  }),
  const ToolDef('propose_void', '提议作废一笔交易。进收件箱。', {
    'type': 'object',
    'properties': {'target_id': {'type': 'string'}, 'reason': {'type': 'string'}},
    'required': ['target_id', 'reason'],
  }),
];

/// 工具实现。任何异常都变成 isError 结果，不让 agent 拿到堆栈。
class LedgerTools {
  final Ledger ledger;
  final QueryEngine engine;
  final String Function() today;
  LedgerTools(this.ledger, {String Function()? today})
      : engine = QueryEngine(ledger),
        today = today ?? _todayLocal;

  static String _todayLocal() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Object? call(String name, Map<String, Object?> args) {
    switch (name) {
      case 'list_accounts':
        return [
          for (final a in ledger.listAccounts()) {...a.toJson(), 'balance': Money(ledger.balance(a.id).minor, a.currency).toDecimalString()},
        ];
      case 'list_categories':
        final kind = args['kind'] as String?;
        return [for (final c in ledger.listCategories(kind: kind == null ? null : enumFromDb(CategoryKind.values, kind))) c.toJson()];
      case 'list_transactions':
        DateTime? p(Object? v) => v is String ? DateTime.parse('${v}T00:00:00Z').subtract(const Duration(days: 1)) : null;
        final to = args['to'] is String ? DateTime.parse('${args['to']}T00:00:00Z').add(const Duration(days: 2)) : null;
        final from = args['from'] as String?;
        final toS = args['to'] as String?;
        return [
          for (final t in ledger.listTransactions(from: p(args['from']), to: to, limit: (args['limit'] as num?)?.toInt() ?? 50))
            if ((from == null || t.occurredAt.localDate.compareTo(from) >= 0) && (toS == null || t.occurredAt.localDate.compareTo(toS) <= 0)) _tx(t),
        ];
      case 'get_transaction':
        return _tx(ledger.getTransaction(args['id'] as String));
      case 'query_ledger':
        return engine.run(QueryDsl.fromJson(args)).toJson();
      case 'detect_anomalies':
        return [for (final a in detectAnomalies(ledger, from: args['from'] as String, to: args['to'] as String)) {...a.toJson(), 'amount': Money(a.tx.amountMinor, a.tx.currency).toDecimalString(), 'date': a.tx.occurredAt.localDate, 'description': a.tx.description}];
      case 'get_budget_status':
        return [
          for (final s in ledger.budgets.statuses(today: (args['today'] as String?) ?? today()))
            {
              'id': s.budget.id,
              'name': s.budget.name,
              'category_id': s.budget.categoryId,
              'period': '${s.from}..${s.to}',
              'limit': Money(s.budget.amountMinor, s.budget.currency).toDecimalString(),
              'spent': Money(s.spentMinor, s.budget.currency).toDecimalString(),
              'remaining': Money(s.remainingMinor, s.budget.currency).toDecimalString(),
              'ratio': s.ratio,
              'over_alert': s.overAlert,
              'exceeded': s.exceeded,
            },
        ];
      case 'list_recurring':
        return [for (final r in ledger.recurring.list()) r.toJson()];
      case 'list_inbox':
        return [for (final d in ledger.listDrafts(status: DraftStatus.pending)) d.toJson()];
      case 'propose_transactions':
        final items = (args['items'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, Object?>()).toList();
        if (items.isEmpty) throw ArgumentError('items is empty');
        final drafts = ledger.propose(
          [for (final it in items) DraftInput(payload: _normalize(it), confidence: 0.7)],
          source: Source.mcp,
          actor: Actor.mcp,
          interpreter: 'mcp',
          modelUsed: args['note'] as String?,
        );
        return {'drafts': drafts.map(_draft).toList(), 'message': '已进收件箱，等待用户在余见里确认；不会自动入账。'};
      case 'propose_update':
        final d = ledger.propose(
          [DraftInput(kind: DraftKind.update, targetTransactionId: args['target_id'] as String, payload: _normalize((args['patch'] as Map).cast<String, Object?>(), partial: true))],
          source: Source.mcp,
          actor: Actor.mcp,
          interpreter: 'mcp',
        ).single;
        return {'draft': _draft(d), 'message': '已进收件箱，等待用户确认。'};
      case 'list_goals':
        final day = (args['today'] as String?) ?? today();
        final m = Wealth(ledger).compute(today: day);
        return [
          for (final g in ledger.goals.list())
            () {
              final p = ledger.goals.progress(g, today: day, liquidMinor: m.liquidMinor, netWorthMinor: m.netWorthMinor);
              return {...g.toJson(), 'saved': Money(p.savedMinor, g.currency).toDecimalString(), 'target': Money(p.targetMinor, g.currency).toDecimalString(), 'ratio': double.parse(p.ratio.toStringAsFixed(3)), 'eta_days': p.etaDays, 'behind_days': p.behindDays, 'milestone': p.milestone};
            }(),
        ];
      case 'get_wealth':
        final m = Wealth(ledger).compute(today: (args['today'] as String?) ?? today());
        String y(int minor) => Money(minor, m.currency).toDecimalString();
        return {
          'disposable': y(m.disposableMinor),
          'daily_allowance': y(m.dailyAllowanceMinor),
          'liquid': y(m.liquidMinor),
          'locked': y(m.lockedMinor),
          'fixed_due_before_payday': y(m.fixedDueMinor),
          'card_owed': y(m.cardOwedMinor),
          'payday': m.payday,
          'payday_source': m.paydaySource,
          'days_to_payday': m.daysToPayday,
          'monthly_spend_avg': y(m.monthlySpendAvgMinor),
          'spend_basis': m.spendBasis.name,
          'runway_months': m.runwayMonths == null ? null : double.parse(m.runwayMonths!.toStringAsFixed(2)),
          'level': m.level?.name,
          'title': m.level?.title,
          'savings_rate': m.savingsRate == null ? null : double.parse(m.savingsRate!.toStringAsFixed(3)),
          'net_worth': y(m.netWorthMinor),
          'assets': y(m.assetsMinor),
          'debt': {'loan': y(m.debt.loanMinor), 'card': y(m.debt.cardMinor), 'monthly_repayment': y(m.debt.monthlyMinor), 'months_left': m.debt.monthsLeft},
          'income_by_line': m.incomeByLine.map((k, v) => MapEntry(k.name, y(v))),
        };
      case 'list_tasks':
        final week = (args['week'] as String?) ?? TaskStore.weekOf(today());
        return [for (final t in ledger.tasks.list(week: week)) {...t.toJson(), 'progress': ledger.tasks.progress(t, today: today()).detail}];
      case 'propose_goal':
        final amount = Money.parse('${args['amount']}', 'CNY').minor;
        return {'proposal': {'kind': args['kind'], 'name': args['name'], 'target_minor': amount, 'deadline': args['deadline'], 'emoji': args['emoji']}, 'message': '这是一份目标草案；余见不会替用户直接创建目标，请把它展示给用户，由用户在余见「目标」页里建。'};
      case 'propose_deposit':
        final g = ledger.goals.get(args['goal_id'] as String);
        final from = (args['from_account_id'] as String?) ?? ledger.listAccounts().first.id;
        final d = ledger.propose(
          [DraftInput(payload: ledger.goals.depositPayload(g, Money.parse('${args['amount']}', g.currency).minor, fromAccountId: from), confidence: 0.7)],
          source: Source.mcp,
          actor: Actor.mcp,
          interpreter: 'mcp',
        ).single;
        return {'draft': _draft(d), 'message': '已进收件箱，等待用户确认；不会自动入账。'};
      case 'propose_void':
        final d = ledger.propose(
          [DraftInput(kind: DraftKind.void_, targetTransactionId: args['target_id'] as String, payload: {'reason': args['reason']})],
          source: Source.mcp,
          actor: Actor.mcp,
          interpreter: 'mcp',
        ).single;
        return {'draft': _draft(d), 'message': '已进收件箱，等待用户确认。'};
      default:
        throw ArgumentError('unknown tool $name');
    }
  }

  Map<String, Object?> _tx(Transaction t) => {
        ...t.toJson(),
        'amount': Money(t.amountMinor, t.currency).toDecimalString(),
        'category': t.categoryId == null ? null : ledger.category(t.categoryId!)?.name,
        'account': ledger.account(t.accountId)?.name,
      };

  Map<String, Object?> _draft(Draft d) => {'id': d.id, 'group_id': d.groupId, 'kind': d.kind.db, 'missing_fields': d.missingFields, 'possible_duplicate_of': d.possibleDuplicateOf, 'payload': d.payload};

  /// 把 agent 友好的 amount 字符串变成 amount_minor；其他字段原样。
  Map<String, Object?> _normalize(Map<String, Object?> it, {bool partial = false}) {
    final out = <String, Object?>{...it};
    final currency = ((out['currency'] as String?) ?? 'CNY').toUpperCase();
    out['currency'] = currency;
    if (out.containsKey('amount') && !out.containsKey('amount_minor')) {
      final a = out.remove('amount');
      out['amount_minor'] = a == null ? null : Money.parse(a.toString(), currency).minor;
    }
    if (partial) {
      out.remove('currency');
      if (it['currency'] != null) out['currency'] = currency;
    }
    return out;
  }
}
