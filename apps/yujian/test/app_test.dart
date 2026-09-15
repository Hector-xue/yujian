import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';

void main() {
  late AppState state;
  setUp(() {
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  testWidgets('home renders and bootstrap seeds accounts', (tester) async {
    await tester.pumpWidget(YujianApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('支出'), findsOneWidget);
    expect(state.accounts.length, 3);
    expect(state.categories.length, 19);
  });

  testWidgets('chat: say → draft card → confirm → transaction exists', (tester) async {
    await tester.pumpWidget(YujianApp(state: state));
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '午饭花了28元');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.text('支出 ¥28.00'), findsOneWidget);
    expect(state.inbox.length, 1);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(state.inbox, isEmpty);
    expect(state.ledger.listTransactions().single.amountMinor, 2800);
    expect(state.ledger.balance('wechat').minor, -2800);
  });

  testWidgets('chat: query renders result card', (tester) async {
    state.addManual({'type': 'expense', 'amount_minor': 1200, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    await tester.pumpWidget(YujianApp(state: state));
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '这个月花了多少');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.text('¥12.00'), findsOneWidget);
    expect(find.textContaining('依据 1 笔交易'), findsOneWidget);
  });

  testWidgets('inbox badge and transactions page', (tester) async {
    state.ledger.propose([DraftInput(payload: {'type': 'expense', 'amount_minor': 500, 'currency': 'CNY', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()})], source: Source.chat);
    await tester.pumpWidget(YujianApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsWidgets); // badge
    await tester.tap(find.text('收件箱'));
    await tester.pumpAndSettle();
    expect(find.textContaining('缺'), findsOneWidget);
    expect(find.text('全部确认'), findsNothing);
  });
}
