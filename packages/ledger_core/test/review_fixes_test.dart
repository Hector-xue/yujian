import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:test/test.dart';

/// 2026-09 全面审查里发现的问题的回归测试（一条问题至少一个用例）。
/// 固定时钟：2026-09-26 14:00 +08:00
final fixedNow = DateTime.utc(2026, 9, 26, 6);

late Ledger ledger;

Map<String, Object?> pay(int minor, String when, {String account = 'wx', String type = 'expense', String? category = 'food'}) => {
      'type': type,
      'amount_minor': minor,
      'currency': 'CNY',
      'account_id': account,
      if (type == 'expense' || type == 'income') 'category_id': category,
      'occurred_at': when,
    };

Transaction commitNew(Map<String, Object?> p, {Source source = Source.manual}) {
  final d = ledger.propose([DraftInput(payload: p)], source: source).single;
  return ledger.commit(d.id);
}

void main() {
  setUp(() {
    ledger = Ledger(openLedgerDatabaseInMemory(), clock: () => fixedNow);
    ledger.seedDefaultCategories();
    ledger.createAccount(id: 'wx', name: '微信', type: AccountType.eWallet, currency: 'CNY');
    ledger.createAccount(id: 'card', name: '旧卡', type: AccountType.bank, currency: 'CNY');
  });

  group('跨来源疑似重复', () {
    test('通知已经记过的一笔，截图又抓到：标成疑似重复（不同指纹也能认出来）', () {
      final first = ledger.propose([DraftInput(payload: pay(1990, '2026-09-26T12:00:00+08:00'), eventFingerprint: 'notif:a', fingerprintIsExact: true)], source: Source.notification).single;
      final tx = ledger.commit(first.id);
      final shot = ledger.propose([DraftInput(payload: pay(1990, '2026-09-26T12:04:00+08:00'), eventFingerprint: 'shot:1:0', fingerprintIsExact: true)], source: Source.screenshot).single;
      expect(shot.possibleDuplicateOf, tx.id);
    });

    test('两条都还在收件箱：后来的指向先来的草稿', () {
      final a = ledger.propose([DraftInput(payload: pay(3600, '2026-09-26T12:00:00+08:00'))], source: Source.notification).single;
      final b = ledger.propose([DraftInput(payload: pay(3600, '2026-09-26T12:08:00+08:00'))], source: Source.screenshot).single;
      expect(b.possibleDuplicateOf, a.id);
    });

    test('时间差超过 10 分钟、金额不同、手动记账：都不算', () {
      commitNew(pay(3600, '2026-09-26T12:00:00+08:00'));
      expect(ledger.propose([DraftInput(payload: pay(3600, '2026-09-26T12:30:00+08:00'))], source: Source.notification).single.possibleDuplicateOf, isNull);
      expect(ledger.propose([DraftInput(payload: pay(3601, '2026-09-26T12:01:00+08:00'))], source: Source.notification).single.possibleDuplicateOf, isNull);
      expect(ledger.propose([DraftInput(payload: pay(3600, '2026-09-26T12:01:00+08:00'))], source: Source.chat).single.possibleDuplicateOf, isNull);
    });
  });

  group('同步', () {
    test('远端删分类、本机还有交易在用：保留分类，不抛外键异常', () {
      final c = ledger.createCategory(name: '咖啡', kind: CategoryKind.expense);
      commitNew(pay(1800, '2026-09-20T12:00:00+08:00', category: c.id));
      final r = ledger.applyRemoteChange(ChangeRecord(seq: 1, entity: 'category', entityId: c.id, deleted: true, payload: null, at: DateTime.utc(2030).millisecondsSinceEpoch, origin: 'dev2', pushed: true), fromDevice: 'dev2');
      expect(r, 'skipped');
      expect(ledger.category(c.id), isNotNull);
      expect(ledger.auditLog().any((e) => e.action == 'sync.delete_kept'), isTrue);
    });

    test('远端删分类、本机没人用：跟着删，记忆里的引用一起清掉', () {
      final c = ledger.createCategory(name: '咖啡', kind: CategoryKind.expense);
      ledger.memory.upsertRaw({'key': '瑞幸', 'kind': 'merchant', 'category_id': c.id});
      final r = ledger.applyRemoteChange(ChangeRecord(seq: 1, entity: 'category', entityId: c.id, deleted: true, payload: null, at: DateTime.utc(2030).millisecondsSinceEpoch, origin: 'dev2', pushed: true), fromDevice: 'dev2');
      expect(r, 'applied');
      expect(ledger.category(c.id), isNull);
      expect(ledger.memory.get('瑞幸')!.categoryId, isNull);
    });

    test('应用失败可以留痕', () {
      final rec = ChangeRecord(seq: 9, entity: 'transaction', entityId: 'x', deleted: false, payload: const {'id': 'x'}, at: 1, origin: 'dev2', pushed: true);
      ledger.recordSyncFailure(rec, fromDevice: 'dev2', error: 'boom');
      expect(ledger.syncFailures().single.targetId, 'x');
    });
  });

  group('逻辑', () {
    test('isPayday：画像日子当天为真；nextPayday 仍是下一个', () {
      ledger.profile.payday = 26;
      expect(Wealth(ledger).isPayday(today: '2026-09-26'), isTrue);
      expect(Wealth(ledger).isPayday(today: '2026-09-25'), isFalse);
      expect(Wealth(ledger).nextPayday(today: '2026-09-26').$1, '2026-10-26');
      ledger.profile.payday = 31;
      expect(Wealth(ledger).isPayday(today: '2026-09-30'), isTrue); // 9 月没有 31 号 → 月底
    });

    test('周期账单落账带 recurring_id', () {
      final r = ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 250000, 'currency': 'CNY', 'account_id': 'wx', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-09-26');
      final tx = ledger.commit(ledger.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480).single.id);
      expect(tx.recurringId, r.id);
    });

    test('发薪日推断：工资优先，大额礼金带不偏；本月工资没到不参与', () {
      for (final m in ['06', '07', '08']) {
        commitNew(pay(800000, '2026-$m-15T12:00:00+08:00', type: 'income', category: 'salary'));
      }
      commitNew(pay(2000000, '2026-08-03T12:00:00+08:00', type: 'income', category: 'gift'));
      commitNew(pay(2000000, '2026-07-03T12:00:00+08:00', type: 'income', category: 'gift'));
      commitNew(pay(50000, '2026-09-05T12:00:00+08:00', type: 'income', category: 'parttime'));
      expect(Wealth(ledger).inferPaydayDay(today: '2026-09-10'), 15);
    });

    test('账户归档后，它上面的历史交易还能改分类；挪到归档账户上仍被拒', () {
      final t = commitNew(pay(5000, '2026-09-01T12:00:00+08:00', account: 'card'));
      ledger.archiveAccount('card');
      final d = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: t.id, payload: {'category_id': 'shopping'})], source: Source.manual).single;
      expect(d.missingFields, isEmpty);
      expect(ledger.commit(d.id).categoryId, 'shopping');
      final t2 = commitNew(pay(100, '2026-09-02T12:00:00+08:00'));
      final bad = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: t2.id, payload: {'account_id': 'card'})], source: Source.manual).single;
      expect(bad.missingFields, contains('account_id'));
    });

    test('失败的起草 + 确认包在一个事务里就不留草稿', () {
      final t = commitNew(pay(100, '2026-09-02T12:00:00+08:00'));
      expect(() => ledger.database.transaction(() {
            final d = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: t.id, payload: {'account_id': 'nope'})], source: Source.manual).single;
            return ledger.commit(d.id);
          }), throwsA(isA<LedgerException>()));
      expect(ledger.listDrafts(status: DraftStatus.pending), isEmpty);
    });

    test('可花的：每周固定支出到发薪前按期数扣；已生成未确认的周期草稿也扣', () {
      ledger.profile.payday = 20; // 今天 9/26 → 下个发薪日 10/20
      ledger.recurring.create(name: '健身', template: {'type': 'expense', 'amount_minor': 10000, 'currency': 'CNY', 'account_id': 'wx', 'category_id': 'entertainment'}, frequency: Frequency.weekly, firstDue: '2026-09-28');
      // 9/28、10/5、10/12、10/19 四次
      expect(Wealth(ledger).compute(today: '2026-09-26').fixedDueMinor, 40000);
      ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 250000, 'currency': 'CNY', 'account_id': 'wx', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-09-26');
      ledger.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480); // 草稿进收件箱，next_due 推到 10/26（发薪后）
      expect(Wealth(ledger).compute(today: '2026-09-26').fixedDueMinor, 40000 + 250000);
    });

    test('多设备：另一台已记了同一期周期账单，这边再确认直接认领', () {
      ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 250000, 'currency': 'CNY', 'account_id': 'wx', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '2026-09-26');
      final mine = ledger.recurring.generateDue(today: '2026-09-26', tzOffsetMinutes: 480).single;
      // 模拟另一台设备同步来一笔同指纹的交易
      final other = Transaction.fromRow({
        'id': 'remote-rent', 'type': 'expense', 'occurred_at_ms': 0, 'tz_offset_min': 480, 'currency': 'CNY', 'merchant': null, 'description': '房租', 'category_id': 'housing',
        'tags': '[]', 'source': 'recurring', 'status': 'confirmed', 'confidence': null, 'refund_of_id': null, 'recurring_id': null, 'event_fingerprint': mine.eventFingerprint,
        'metadata': '{}', 'created_at': 0, 'updated_at': 0,
      }, const [Posting(id: 'p', transactionId: 'remote-rent', accountId: 'wx', amountMinor: -250000)]);
      ledger.applyRemoteChange(ChangeRecord(seq: 1, entity: 'transaction', entityId: 'remote-rent', deleted: false, payload: other.toJson(), at: DateTime.utc(2030).millisecondsSinceEpoch, origin: 'dev2', pushed: true), fromDevice: 'dev2');
      final t = ledger.commit(mine.id);
      expect(t.id, 'remote-rent');
      expect(ledger.countTransactions(), 1);
      expect(ledger.getDraft(mine.id).status, DraftStatus.committed);
    });

    test('释放锁仓按比例退回，加起来正好等于余额', () {
      ledger.createAccount(id: 'a', name: 'A', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
      ledger.createAccount(id: 'b', name: 'B', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
      ledger.createAccount(id: 'c', name: 'C', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 100000);
      final g = ledger.goals.create(kind: GoalKind.wish, name: '心愿', targetMinor: 1000000);
      for (final (acc, amt) in [('wx', 45), ('a', 45), ('b', 5), ('c', 5)]) {
        commitNew(ledger.goals.depositPayload(g, amt, fromAccountId: acc));
      }
      // 花掉一点让余额和存入总额不成整比
      commitNew(ledger.goals.redeemPayload(g, 90, categoryId: 'shopping'));
      final backs = ledger.goals.releasePayloads(g, fallbackAccountId: 'wx');
      expect(backs.fold<int>(0, (a, b) => a + (b['amount_minor'] as int)), 10);
    });

    test('新版本同步来的未知枚举值不让老版本崩', () {
      ledger.recurring.upsertRaw({'id': 'r1', 'name': 'x', 'template': {'type': 'expense', 'amount_minor': 1, 'currency': 'CNY'}, 'frequency': 'hourly', 'next_due': '2026-10-01'});
      expect(ledger.recurring.get('r1').frequency, Frequency.monthly);
      ledger.goals.upsertRaw({'id': 'g1', 'kind': 'future_kind', 'name': 'G', 'target_minor': 5, 'currency': 'CNY', 'rules': [{'kind': 'lottery'}, {'kind': 'fixed', 'amount_minor': 100}], 'status': 'paused'});
      final g = ledger.goals.get('g1');
      expect(g.kind, GoalKind.wish);
      expect(g.rules.single.kind, GoalRuleKind.fixed);
      ledger.tasks.upsertRaw({'id': 't1', 'week': '2026-09-21', 'kind': 'future_task', 'params': {}, 'title': 'x'});
      expect(ledger.tasks.list(), isEmpty);
    });
  });

  test('退款原单：商户对得上优先；否则只在剩余可退金额唯一相等时认', () {
    final meituan = commitNew({...pay(3250, '2026-09-20T12:00:00+08:00'), 'merchant': '美团'});
    commitNew({...pay(3250, '2026-09-21T12:00:00+08:00'), 'merchant': '饿了么'});
    expect(ledger.guessRefundOriginal(amountMinor: 1000, currency: 'CNY', merchant: '美团'), meituan.id);
    expect(ledger.guessRefundOriginal(amountMinor: 3250, currency: 'CNY'), isNull); // 两笔都是 32.5，拿不准
    expect(ledger.guessRefundOriginal(amountMinor: 999999, currency: 'CNY', merchant: '美团'), isNull); // 超过原单
  });
}
