import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/settings_store.dart';

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
    expect(find.text('已记 1 笔。'), findsOneWidget); // 极简助手的人格回复
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
    expect(find.textContaining('缺'), findsWidgets);
    final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认'));
    expect(confirm.onPressed, isNull); // 缺字段时不能确认
  });

  testWidgets('settings: persona switch changes chat voice; model config builds interpreter', (tester) async {
    await state.saveSettings(const Settings(personaId: 'catgirl'));
    await tester.pumpWidget(YujianApp(state: state));
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    expect(find.text('猫娘'), findsOneWidget);
    expect(find.textContaining('喵'), findsWidgets);
    expect(state.hasModel, isFalse);
    await state.saveSettings(const Settings(personaId: 'catgirl', baseUrl: 'http://127.0.0.1:1/v1', model: 'm', apiKey: 'k'));
    expect(state.hasModel, isTrue);
    expect(state.interpreter.llm, isNotNull);
  });

  testWidgets('import bill csv lands in inbox with mapped category/account; re-import dedupes', (tester) async {
    const csv = '交易时间,交易类型,交易对方,商品,收/支,支付方式,金额(元),当前状态\n'
        '2026-09-14 12:31:05,商户消费,瑞幸咖啡,拿铁,支出,零钱,¥19.00,支付成功\n'
        '2026-09-14 20:10:00,转账,张三,转账,收入,/,¥200.00,已收钱\n';
    final r = state.importBillCsv(csv);
    expect(r.drafts, 2);
    expect(r.error, isNull);
    final drafts = state.inbox;
    final coffee = drafts.firstWhere((d) => d.payload['amount_minor'] == 1900);
    expect(coffee.payload['category_id'], 'food');
    expect(coffee.payload['account_id'], 'wechat');
    expect(coffee.source, Source.import_);
    final again = state.importBillCsv(csv);
    expect(again.drafts, 0);
    expect(again.deduped, 2);
    await tester.pumpWidget(YujianApp(state: state));
    await tester.tap(find.text('收件箱'));
    await tester.pumpAndSettle();
    expect(find.text('全部确认'), findsOneWidget);
  });
}
