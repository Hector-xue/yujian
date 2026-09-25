import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:notification_templates/notification_templates.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/notifications/notification_source.dart';
import 'package:yujian/src/pages/inbox_page.dart';
import 'package:yujian/src/settings_store.dart';
import 'package:yujian/src/theme.dart';
import 'package:yujian/src/widgets/draft_source.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('通知进来的：写明哪个 App 的通知、原文、本机模板', () async {
    final src = FakeNotificationSource(enabled: true);
    final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
    await st.saveSettings(const Settings(notificationsWanted: true));
    src.queue.add(NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: '已支付¥19.90，商户：瑞幸咖啡', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'k1'));
    expect(await st.startNotifications(), 1);
    final o = describeDraftOrigin(st, st.inbox.single);
    expect(o.label, '微信 通知');
    expect(o.details, contains(('原文', '已支付¥19.90，商户：瑞幸咖啡')));
    expect(o.details.any((e) => e.$1 == '认法' && e.$2.contains('不经过模型')), isTrue);
    expect(o.hint, isNotNull);
  });

  test('支付页识别进来的：和通知区分开', () async {
    final src = FakeNotificationSource(enabled: false)
      ..queue.add(NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付 支付成功页', text: '支付成功 ¥13.80 商户：杨国福麻辣烫', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'screen:com.tencent.mm:13.80:1', source: 'screen'));
    final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
    await st.saveSettings(const Settings(screenWanted: true));
    expect(await st.startNotifications(), 1);
    expect(describeDraftOrigin(st, st.inbox.single).label, '微信 支付页识别');
  });

  test('周期账单到期的：写出是哪个账单', () {
    final st = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
    final t = DateTime.now();
    final ym = '${t.year}-${t.month.toString().padLeft(2, '0')}';
    st.ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 220000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '$ym-01');
    expect(st.generateRecurring(), 1);
    expect(describeDraftOrigin(st, st.inbox.single).label, '周期账单「房租」到期');
  });

  test('确切时间到秒', () {
    expect(fmtExactTime(DateTime(2026, 9, 5, 7, 3, 9)), '2026-09-05 07:03:09');
  });

  testWidgets('收件箱每组顶上有来源行，点开看确切进来时间和原文', (tester) async {
    final src = FakeNotificationSource(enabled: true);
    final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
    await tester.runAsync(() async {
      await st.saveSettings(const Settings(notificationsWanted: true));
      src.queue.add(NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: '已支付¥19.90，商户：瑞幸咖啡', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'k1'));
      await st.startNotifications();
    });
    await tester.pumpWidget(AppScope(state: st, child: MaterialApp(theme: buildTheme(), home: const InboxPage())));
    await tester.pumpAndSettle();
    expect(find.textContaining('微信 通知 · '), findsOneWidget);
    await tester.tap(find.text('从哪来的'));
    await tester.pumpAndSettle();
    expect(find.text('进入收件箱'), findsOneWidget);
    expect(find.text('已支付¥19.90，商户：瑞幸咖啡'), findsOneWidget);
  });
}
