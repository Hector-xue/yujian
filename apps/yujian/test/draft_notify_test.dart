import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:notification_templates/notification_templates.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/notifications/draft_notifier.dart';
import 'package:yujian/src/notifications/notification_source.dart';
import 'package:yujian/src/pages/inbox_page.dart';
import 'package:yujian/src/settings_store.dart';
import 'package:yujian/src/theme.dart';

/// 记账后弹通知：什么时候弹、弹什么、通知栏上点了 确认 / 忽略 / 撤销 怎么落账、在 App 里处理掉的通知撤下来。
class FakeDraftNotifier implements DraftNotifier {
  bool permitted;
  FakeDraftNotifier({this.permitted = true});
  final posted = <DraftNotice>[];
  final cancelled = <String>[];
  final queued = <DraftAction>[];
  bool? paymentsWanted;

  @override
  bool get supported => true;
  @override
  Future<bool> canPost() async => permitted;
  @override
  Future<bool> requestPermission() async => permitted;
  @override
  Future<void> post(List<DraftNotice> items) async => posted.addAll(items);
  @override
  Future<void> cancel(List<String> tags) async => cancelled.addAll(tags);
  @override
  Future<List<DraftAction>> drainActions() async {
    final out = [...queued];
    queued.clear();
    return out;
  }

  @override
  Stream<void> get actions => const Stream.empty();
  @override
  Future<void> setPaymentsWanted(bool v) async => paymentsWanted = v;
  @override
  Future<void> backgroundDone() async {}
}

void main() {
  NotificationEvent wechat(String text, {required String key}) => NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch, key: key);

  late FakeDraftNotifier fake;
  late AppState st;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fake = FakeDraftNotifier();
    st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: FakeNotificationSource(enabled: true), drafts: fake)..bootstrap();
  });

  Future<void> on({AutomationMode mode = AutomationMode.confirm}) async {
    await st.saveSettings(Settings(notificationsWanted: true, automationMode: mode));
    expect(await st.setDraftNotify(true), isTrue);
    st.inForeground = false;
  }

  group('什么时候弹', () {
    test('没开「记账后弹通知」：不弹（老用户升级后行为不变）', () async {
      await st.saveSettings(const Settings(notificationsWanted: true));
      st.inForeground = false;
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
      await st.flushBackground();
      expect(fake.posted, isEmpty);
      expect(st.inbox, hasLength(1), reason: '起草照旧');
    });
    test('App 在前台：不弹', () async {
      await on();
      st.inForeground = true;
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
      await st.flushBackground();
      expect(fake.posted, isEmpty);
    });
    test('没拿到权限：开不起来', () async {
      fake.permitted = false;
      expect(await st.setDraftNotify(true), isFalse);
      expect(st.settings.draftNotify, isFalse);
    });
    test('后台处理付款通知的开关跟着设置走（要同时开了通知 / 支付页记账）', () async {
      await st.saveSettings(const Settings(draftNotify: true));
      await Future<void>.delayed(Duration.zero);
      expect(fake.paymentsWanted, isFalse);
      await st.saveSettings(const Settings(draftNotify: true, screenWanted: true));
      await Future<void>.delayed(Duration.zero);
      expect(fake.paymentsWanted, isTrue);
      await st.saveSettings(const Settings(screenWanted: true));
      await Future<void>.delayed(Duration.zero);
      expect(fake.paymentsWanted, isFalse);
    });
  });

  group('弹什么', () {
    test('确认模式：待确认，带「确认」；没认出商户的照样能确认（落到「其他」）', () async {
      await on();
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
      await st.flushBackground();
      final n = fake.posted.single;
      final d = st.inbox.single;
      expect((n.kind, n.tag, n.target, n.canConfirm), ('pending', d.id, d.id, true));
      expect(n.title, contains('¥19.90'));
      expect(n.text, contains('瑞幸咖啡'));
    });
    test('疑似重复：不给「确认」', () async {
      await on();
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'b')]); // 不同通知、同额同商户：疑似重复
      await st.flushBackground();
      final dup = st.inbox.firstWhere((d) => d.possibleDuplicateOf != null);
      final n = fake.posted.firstWhere((x) => x.tag == dup.id);
      expect(n.canConfirm, isFalse);
      expect(n.text, contains('重复'));
    });
    test('静默模式：自动记下的弹「已记」，带撤销（tag = tx:交易 id）', () async {
      await on(mode: AutomationMode.silent);
      st.ingestNotifications([wechat('已支付¥66.00', key: 'a')]);
      await st.flushBackground();
      final tx = st.ledger.listTransactions().single;
      final n = fake.posted.single;
      expect((n.kind, n.tag, n.target), ('committed', 'tx:${tx.id}', tx.id));
      expect(n.title, startsWith('已记'));
    });
  });

  group('通知栏上点了按钮', () {
    test('确认 → 入账、撤下通知；重复点（已处理）跳过', () async {
      await on();
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
      final d = st.inbox.single;
      fake.queued.addAll([DraftAction(op: 'confirm', tag: d.id, target: d.id), DraftAction(op: 'confirm', tag: d.id, target: d.id)]);
      expect(await st.handleDraftActions(), 1);
      expect(st.ledger.listTransactions().single.amountMinor, 1990);
      expect(st.inbox, isEmpty);
      expect(fake.cancelled, contains(d.id));
    });
    test('忽略 → 草稿忽略、不入账', () async {
      await on();
      st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
      final d = st.inbox.single;
      fake.queued.add(DraftAction(op: 'dismiss', tag: d.id, target: d.id));
      expect(await st.handleDraftActions(), 1);
      expect(st.inbox, isEmpty);
      expect(st.ledger.listTransactions(), isEmpty);
    });
    test('撤销 → 自动记下的那笔作废', () async {
      await on(mode: AutomationMode.silent);
      st.ingestNotifications([wechat('已支付¥66.00', key: 'a')]);
      final tx = st.ledger.listTransactions().single;
      fake.queued.add(DraftAction(op: 'undo', tag: 'tx:${tx.id}', target: tx.id));
      expect(await st.handleDraftActions(), 1);
      expect(st.ledger.getTransaction(tx.id).status, TransactionStatus.void_);
      expect(fake.cancelled, contains('tx:${tx.id}'));
    });
    test('草稿已经不在了（别的设备删了）：弹「没记上」，不崩', () async {
      await on();
      fake.queued.add(const DraftAction(op: 'confirm', tag: 'nope', target: 'nope'));
      expect(await st.handleDraftActions(), 0);
      expect(fake.posted.single.kind, 'failed');
    });
  });

  test('在 App 里确认 / 忽略 / 作废：对应通知撤下来', () async {
    await on();
    st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a'), wechat('已支付¥8.00，商户：地铁', key: 'b')]);
    final ds = st.inbox;
    st.commit(ds[0].id);
    st.dismiss(ds[1].id);
    expect(fake.cancelled, containsAll([ds[0].id, ds[1].id]));
    final tx = st.ledger.listTransactions().single;
    st.voidTransaction(tx.id, 'x');
    expect(fake.cancelled, contains('tx:${tx.id}'));
  });

  testWidgets('收件箱顶上的提示：开了自动记账、没开弹通知时出现；点「打开」就开', (tester) async {
    await st.saveSettings(const Settings(notificationsWanted: true));
    st.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a')]);
    await tester.pumpWidget(AppScope(state: st, child: MaterialApp(theme: buildTheme(), home: const InboxPage())));
    await tester.pumpAndSettle();
    expect(find.text('不用每次打开这里确认'), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(st.settings.draftNotify, isTrue);
    expect(find.text('不用每次打开这里确认'), findsNothing);
  });
}
