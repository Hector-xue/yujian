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
}
