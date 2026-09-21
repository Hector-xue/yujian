import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:notification_templates/notification_templates.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/pages/more_page.dart';
import 'package:yujian/src/pages/support_page.dart';
import 'package:yujian/src/support/support_config.dart';
import 'package:yujian/src/theme.dart';

void main() {
  late AppState state;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  String day(int offset) {
    final d = DateTime.now().add(Duration(days: offset));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object?> expense(int minor) => {'type': 'expense', 'amount_minor': minor, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': '${day(0)}T12:00:00+08:00'};

  group('support prompt', () {
    test('appears after 30 records; snooze hides it for 30 days; marking hides it for good and unlocks the achievement', () async {
      expect(state.supportPromptVisible, isFalse); // 新装：没到门槛不提
      for (var i = 0; i < SupportConfig.minTransactions - 1; i++) {
        state.addManual(expense(100 + i));
      }
      expect(state.supportPromptVisible, isFalse);
      state.addManual(expense(999));
      expect(state.supportPromptVisible, isTrue);

      state.snoozeSupport();
      expect(state.supportPromptVisible, isFalse);
      expect(state.ledger.profile.supportSnoozeUntil, day(SupportConfig.snoozeDays));
      state.ledger.profile.supportSnoozeUntil = day(-1); // 到期
      expect(state.supportPromptVisible, isTrue);

      state.markSupporter(via: 'manual');
      expect(state.isSupporter, isTrue);
      expect(state.ledger.profile.supporterSince, day(0));
      expect(state.ledger.profile.supportSnoozeUntil, isNull);
      expect(state.supportPromptVisible, isFalse);
      // 成就 + 道谢在下一轮重算里
      await state.game.recompute();
      await Future<void>.delayed(Duration.zero);
      expect(state.game.achievements.map((a) => a.key), contains('support.yujian'));
      expect(state.game.pendingMessages.map((m) => m.text).join(), contains('收到你的一块钱'));
      // 再标一次不动日期
      state.ledger.profile.supporterSince = '2020-01-01';
      state.markSupporter(via: 'manual');
      expect(state.ledger.profile.supporterSince, '2020-01-01');
    });

    test('the ¥1 payment is recognised only inside the window after tapping pay, and only for the exact amount', () {
      NotificationEvent wechat(String text, {String? source}) => NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'k-$text', source: source);
      // 没点过付款按钮：¥1 只是普通一笔
      state.ingestNotifications([wechat('已支付¥1.00，商户：某某')]);
      expect(state.isSupporter, isFalse);
      // 点了付款按钮：金额不对不算
      state.noteSupportPayTapped();
      state.ingestNotifications([wechat('已支付¥19.90，商户：瑞幸咖啡')]);
      expect(state.isSupporter, isFalse);
      // 收入不算
      state.ingestNotifications([NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: '微信支付收款1.00元', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'in')]);
      expect(state.isSupporter, isFalse);
      // 支付页识别到 ¥1.00 → 算
      state.ingestNotifications([wechat('支付成功 ¥1.00 商户：余见', source: 'screen')]);
      expect(state.isSupporter, isTrue);
      expect(state.supportMarkedVia, 'screen');
      expect(state.supportPayTappedAt, isNull);
      // 那笔 ¥1 照常进收件箱（它确实是一笔支出）
      expect(state.inbox.where((d) => d.payload['amount_minor'] == 100), isNotEmpty);
    });

    test('window expires', () {
      state.noteSupportPayTapped();
      state.supportPayTappedAt = DateTime.now().subtract(SupportConfig.detectWindow + const Duration(seconds: 1));
      state.ingestNotifications([NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: '已支付¥1.00，商户：某某', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'late')]);
      expect(state.isSupporter, isFalse);
      expect(state.supportPayTappedAt, isNull); // 过期即清，之后的 ¥1 不再被认
    });

    testWidgets('more page: card on top once due; support page "我已支持" marks and the card goes away', (tester) async {
      for (var i = 0; i < SupportConfig.minTransactions; i++) {
        state.addManual(expense(100 + i));
      }
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const MorePage())));
      await tester.pumpAndSettle();
      expect(find.text('支持余见 ¥1'), findsOneWidget);
      await tester.tap(find.text('支持余见 ¥1'));
      await tester.pumpAndSettle();
      expect(find.byType(SupportPage), findsOneWidget);
      expect(find.text('我已支持，永久关闭'), findsOneWidget);
      expect(find.text('先不了，${SupportConfig.snoozeDays} 天后再说'), findsOneWidget);
      await tester.tap(find.text('我已支持，永久关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(state.isSupporter, isTrue);
      expect(find.text('我已支持，永久关闭'), findsNothing);
      expect(find.textContaining('支持过余见'), findsOneWidget);
      // 回到更多页：顶部卡没了，「关于」里的入口写已支持
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('支持余见 ¥1'), findsNothing);
      await tester.scrollUntilVisible(find.text('已支持 · 谢谢'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('已支持 · 谢谢'), findsOneWidget);
    });

    testWidgets('support page: "30 天后再说" snoozes and pops', (tester) async {
      for (var i = 0; i < SupportConfig.minTransactions; i++) {
        state.addManual(expense(100 + i));
      }
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const MorePage())));
      await tester.pumpAndSettle();
      await tester.tap(find.text('支持余见 ¥1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('先不了，${SupportConfig.snoozeDays} 天后再说'));
      await tester.pumpAndSettle();
      expect(find.byType(SupportPage), findsNothing);
      expect(state.supportPromptVisible, isFalse);
      expect(find.text('支持余见 ¥1'), findsNothing);
    });

    test('QR renders to a white-background PNG', () async {
      final png = await renderQrPng('https://qr.alipay.com/test', 240);
      expect(png, isNotNull);
      expect(png!.length, greaterThan(100));
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });
}
