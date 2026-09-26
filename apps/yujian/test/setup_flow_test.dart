import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/pages/chat_page.dart';
import 'package:yujian/src/theme.dart';

/// 对话建档：一句话 → 建档卡 → 追问 → 确认 → 建好（能撤销）；普通记账句照旧。
void main() {
  late AppState state;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  // 还款日避开今天（今天正好是还款日会多问一句「这期还了没」，单独测）
  final d = DateTime.now().day == 15 ? 16 : 15;

  group('AppState', () {
    test('需求原句：认成建档，不进记账', () async {
      final r = await state.trySetup('欠白条5000，每月$d号还1000');
      expect(r, isNotNull);
      final it = r!.items.single;
      expect((it.kind, it.name, it.principalMinor, it.monthlyMinor, it.day), (SetupKind.loan, '京东白条', 500000, 100000, d));
      expect(state.inbox, isEmpty, reason: '建档不起草记账');
      final g = await state.trySetup('工行定期一万');
      expect(g!.items.single.assetType, AccountType.investment);
    });
    test('普通记账 / 还款 / 查询：trySetup 返回 null，say 和以前一样', () async {
      for (final s in ['午饭花了28元', '还了白条1000', '借给小李3000', '这个月花了多少']) {
        expect(await state.trySetup(s), isNull, reason: s);
      }
      final r = await state.say('午饭花了28元');
      expect(r.drafts, hasLength(1));
    });
    test('确认建立 → 负债合计 / 净资产变化；撤销干净', () async {
      final it = (await state.trySetup('欠白条5000，每月$d号还1000'))!.items.single..fromAccountId = 'wechat';
      final before = state.debtTotals().totalMinor;
      final applied = state.applySetup([it]);
      expect(state.debtTotals().totalMinor - before, 500000);
      expect(state.ledger.recurring.list(), hasLength(1));
      expect(state.undoSetup(applied), 1);
      expect(state.debtTotals().totalMinor, before);
      expect(state.ledger.recurring.list(activeOnly: false), isEmpty);
    });
    test('扣款账户：设了默认账户就不用问', () async {
      state.ledger.profile.defaultAccountId = 'alipay';
      final it = (await state.trySetup('欠白条5000，每月$d号还1000'))!.items.single;
      expect(it.fromAccountId, 'alipay');
      expect(it.ready(state.setupEnv()), isTrue);
    });
  });

  group('对话页', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const ChatPage())));
      await tester.pumpAndSettle();
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
    }

    testWidgets('白条：问扣款账户（点选项）→ 确认建立 → 撤销', (tester) async {
      await pump(tester);
      await send(tester, '欠白条5000，每月$d号还1000');
      expect(find.text('我理解的是'), findsOneWidget);
      expect(find.textContaining('欠「京东白条」¥5000.00'), findsOneWidget);
      expect(find.text('「京东白条」从哪个账户还？'), findsOneWidget);
      expect(state.inbox, isEmpty);
      await tester.tap(find.widgetWithText(ActionChip, '支付宝'));
      await tester.pumpAndSettle();
      expect(find.text('「京东白条」从哪个账户还？'), findsOneWidget, reason: '问题留在对话里');
      await tester.tap(find.widgetWithText(FilledButton, '确认建立'));
      await tester.pumpAndSettle();
      expect(find.text('建好了'), findsOneWidget);
      final acc = state.ledger.listAccounts().where((a) => a.name == '京东白条').single;
      expect(acc.type, AccountType.payable);
      expect(state.ledger.recurring.list().single.template['account_id'], 'alipay');
      await tester.tap(find.widgetWithText(TextButton, '撤销'));
      await tester.pumpAndSettle();
      expect(find.text('已撤销'), findsOneWidget);
      expect(state.ledger.account(acc.id), isNull);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('打字回答：定期「钱从哪来」→ 单独记 → 到期日跳过 → 说「确认」', (tester) async {
      await pump(tester);
      await send(tester, '存了一万定期');
      expect(find.textContaining('是从你已有的账户转过去的吗'), findsOneWidget);
      await send(tester, '不是');
      expect(find.textContaining('什么时候到期'), findsOneWidget);
      await send(tester, '跳过');
      await send(tester, '确认');
      expect(find.text('建好了'), findsOneWidget);
      final a = state.ledger.listAccounts().where((a) => a.name == '定期存款').single;
      expect((a.type, a.initialBalanceMinor), (AccountType.investment, 1000000));
      expect(state.inbox, isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('追问中插一句记账：追问放下，这句照常起草；点「继续」接着问', (tester) async {
      await pump(tester);
      await send(tester, '欠白条5000，每月$d号还1000');
      await send(tester, '午饭花了28元');
      expect(find.widgetWithText(FilledButton, '继续'), findsOneWidget);
      expect(state.inbox, hasLength(1), reason: '午饭照常进收件箱');
      expect(state.ledger.listAccounts().where((a) => a.name == '京东白条'), isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pumpAndSettle();
      await send(tester, '微信');
      expect(find.widgetWithText(FilledButton, '确认建立'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('「算了」取消；已有账户只指路不建；「登记负债 / 资产」模式', (tester) async {
      await pump(tester);
      await send(tester, '欠白条5000，每月$d号还1000');
      await send(tester, '算了');
      expect(find.text('没建'), findsOneWidget);
      await send(tester, '现金有2000');
      expect(find.text('这些已经有了'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认建立'), findsNothing);
      await tester.tap(find.text('登记负债 / 资产'));
      await tester.pumpAndSettle();
      await send(tester, '随便说点什么');
      expect(find.textContaining('没看出是哪笔欠款或存款'), findsOneWidget);
      expect(state.inbox, isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('重开对话页：没问完的卡放下，隔天说「好」不会确认', (tester) async {
      await pump(tester);
      await send(tester, '工行定期一万');
      await tester.pump(const Duration(seconds: 1)); // 落盘
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(find.widgetWithText(FilledButton, '继续'), findsOneWidget);
      await send(tester, '好');
      expect(state.ledger.listAccounts().where((a) => a.name == '工行定期'), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      final hist = jsonDecode(prefs.getString('chat_history_v1') ?? '[]') as List;
      expect(hist.any((m) => (m as Map)['t'] == 'setup'), isTrue);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
