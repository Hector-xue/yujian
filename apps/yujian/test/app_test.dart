import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:notification_templates/notification_templates.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/notifications/notification_source.dart';
import 'package:yujian/src/settings_store.dart';

void main() {
  late AppState state;
  setUp(() {
    SharedPreferences.setMockInitialValues({}); // 对话历史 / 更新检查落盘用
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  testWidgets('home renders and bootstrap seeds accounts', (tester) async {
    await tester.pumpWidget(YujianApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('本月支出'), findsOneWidget);
    expect(find.text('余额'), findsOneWidget);
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

  testWidgets('chat: small talk goes to the companion; memory is kept and shown in settings', (tester) async {
    await tester.pumpWidget(YujianApp(state: state));
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    // 没模型：直说去配，不再是「没听懂」
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.textContaining('先在「更多 → 模型与人格」配一个模型'), findsOneWidget);
    expect(state.inbox, isEmpty);

    // 有模型（假的）：走陪聊，回复带模型名，记住的事落盘
    state.companion = CompanionReplier(state.persona, _FakeChat('{"reply":"你好呀，今天过得怎么样？","sticker":"🌱","remember":["用户叫小雪"]}'));
    await tester.enterText(find.byType(TextField), '我叫小雪');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.text('你好呀，今天过得怎么样？'), findsOneWidget);
    expect(find.text('🌱'), findsOneWidget);
    expect(find.text('fake-model · 陪聊'), findsOneWidget);
    expect(state.memory.lines, ['用户叫小雪']);
    expect(state.inbox, isEmpty);
    // 记账的话仍然走草稿，不会被陪聊吃掉
    await tester.enterText(find.byType(TextField), '打车 36');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(state.inbox.length, 1);
  });

  test('ledger brief only states real numbers', () {
    expect(state.ledgerBrief(), contains('账本还是空的'));
    state.addManual({'type': 'expense', 'amount_minor': 1380, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'description': '麻辣烫', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    final b = state.ledgerBrief();
    expect(b, contains('今天支出 ¥13.80（1 笔）'));
    expect(b, contains('麻辣烫'));
    expect(b, isNot(contains('账本还是空的')));
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

  testWidgets('recurring due → inbox draft; budget alert shows on home', (tester) async {
    final today = DateTime.now();
    final ym = '${today.year}-${today.month.toString().padLeft(2, '0')}';
    state.ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 220000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'housing'}, frequency: Frequency.monthly, firstDue: '$ym-01');
    expect(state.generateRecurring(), 1);
    expect(state.inbox.single.source, Source.recurring);
    state.ledger.budgets.create(name: '吃饭', categoryId: 'food', amountMinor: 10000, startDate: '$ym-01');
    state.addManual({'type': 'expense', 'amount_minor': 9000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    await tester.pumpWidget(YujianApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('吃饭'), findsOneWidget);
    expect(find.textContaining('还剩 ¥10.00'), findsOneWidget);
  });

  group('notifications', () {
    NotificationEvent wechat(String text, {String? key}) => NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付', text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch, key: key);

    test('confirm mode: drafts only; exact key dedupes; ignored skipped', () async {
      final src = FakeNotificationSource(enabled: true);
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
      await st.saveSettings(const Settings(notificationsWanted: true));
      src.queue.addAll([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'k1'), wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'k1'), wechat('您有一张优惠券即将过期，立即领取')]);
      expect(await st.startNotifications(), 1);
      final d = st.inbox.single;
      expect(d.source, Source.notification);
      expect(d.payload['amount_minor'], 1990);
      expect(d.payload['category_id'], 'food');
      expect(d.payload['account_id'], 'wechat');
      expect(d.payload['merchant'], '瑞幸咖啡');
      expect(st.ledger.listTransactions(), isEmpty);
      // 实时流
      src.emit(wechat('已支付¥8.00，商户：地铁', key: 'k2'));
      await Future<void>.delayed(Duration.zero);
      expect(st.inbox.length, 2);
    });

    test('smart mode auto-commits confident ones, keeps unclear in inbox', () async {
      final src = FakeNotificationSource(enabled: true);
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
      await st.saveSettings(const Settings(notificationsWanted: true, automationMode: AutomationMode.smart));
      src.queue.addAll([wechat('已支付¥19.90，商户：瑞幸咖啡', key: 'a'), wechat('已支付¥66.00', key: 'b')]);
      await st.startNotifications();
      expect(st.ledger.listTransactions().single.amountMinor, 1990);
      expect(st.inbox.single.payload['amount_minor'], 6600); // 没商户没分类 → 收件箱
    });

    test('silent mode commits with 其他 when category is unknown; text without an amount is dropped', () async {
      final src = FakeNotificationSource(enabled: true);
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
      await st.saveSettings(const Settings(notificationsWanted: true, automationMode: AutomationMode.silent));
      src.queue.addAll([wechat('已支付¥66.00', key: 'b'), NotificationEvent(packageName: 'com.eg.android.AlipayGphone', title: '支付宝', text: '你有一笔新的交易，点击查看', postedAtMs: 1, key: 'c'), wechat('【微信】验证码 999999，请勿泄露', key: 'd')]);
      await st.startNotifications();
      final tx = st.ledger.listTransactions().single; // 66 猜不出分类 → 其他 → 静默模式照样入账
      expect(tx.amountMinor, 6600);
      expect(tx.categoryId, 'other_expense');
      expect(st.inbox, isEmpty); // 没金额的通知不是账，不进收件箱
    });

    test('smart mode does not auto-commit a fallback category', () async {
      final src = FakeNotificationSource(enabled: true)..queue.add(wechat('已支付¥66.00', key: 'b'));
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
      await st.saveSettings(const Settings(notificationsWanted: true, automationMode: AutomationMode.smart));
      await st.startNotifications();
      expect(st.ledger.listTransactions(), isEmpty);
      expect(st.inbox.single.payload['category_id'], 'other_expense');
      expect(st.inbox.single.missingFields, isEmpty);
    });

    test('screen recognition alone drains the same queue; shopping app lands on default account', () async {
      final src = FakeNotificationSource(enabled: false)
        ..queue.addAll([
          NotificationEvent(packageName: 'com.tencent.mm', title: '微信支付 支付成功页', text: '支付成功 ¥13.80 商户：杨国福麻辣烫', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'screen:com.tencent.mm:13.80:1', source: 'screen'),
          NotificationEvent(packageName: 'com.jingdong.app.mall', title: '京东 支付成功页', text: '支付成功 ¥199.00', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'screen:com.jingdong.app.mall:199.00:1', source: 'screen'),
        ]);
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
      await st.saveSettings(const Settings(screenWanted: true));
      expect(await st.startNotifications(), 2);
      final mlt = st.inbox.firstWhere((d) => d.payload['amount_minor'] == 1380);
      expect(mlt.payload['account_id'], 'wechat');
      expect(mlt.payload['category_id'], 'food');
      expect(((mlt.payload['metadata'] as Map)['notification'] as Map)['source'], 'screen');
      final jd = st.inbox.firstWhere((d) => d.payload['amount_minor'] == 19900);
      expect(jd.payload['account_id'], 'wechat', reason: '购物平台不知道走哪个渠道，落默认账户');
      expect(st.showAutoHint, isFalse);
    });

    test('notifications off → nothing ingested', () async {
      final src = FakeNotificationSource(enabled: true)..queue.add(wechat('已支付¥1.00', key: 'z'));
      final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
      expect(await st.startNotifications(), 0);
      expect(st.inbox, isEmpty);
    });
  });

  test('user notification templates and custom persona are honored', () async {
    final src = FakeNotificationSource(enabled: true);
    final st = AppState(Ledger(openLedgerDatabaseInMemory()), notifications: src)..bootstrap();
    await st.saveSettings(Settings(
      notificationsWanted: true,
      userTemplates: [
        {'id': 'canteen', 'packages': ['com.school.canteen'], 'text_re': r'消费(?<amount>\d+\.\d\d)元', 'direction': 'expense', 'confidence': 0.95},
        {'id': 'broken', 'text_re': '(('}, // 坏模板被跳过
      ],
      personaId: 'pirate',
      customPersona: {'id': 'pirate', 'name': '海盗', 'tagline': 'arr', 'style': '像海盗一样说话', 'templates': {for (final e in PersonaEvent.values) e.name: 'arr {n}'}},
    ));
    expect(st.persona.name, '海盗');
    expect(st.replier.template(PersonaEvent.recorded, n: 2), 'arr 2');
    src.queue.add(NotificationEvent(packageName: 'com.school.canteen', title: '食堂', text: '消费12.50元 余额88.00元', postedAtMs: DateTime.now().millisecondsSinceEpoch, key: 'c1'));
    await st.startNotifications();
    expect(st.inbox.single.payload['amount_minor'], 1250);
    expect(st.inbox.single.interpreter, 'notification:canteen');
  });

  testWidgets('transaction edit sheet updates amount/category/time via update draft', (tester) async {
    final tx = state.addManual({'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'description': '午饭', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    await tester.pumpWidget(YujianApp(state: state));
    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('午饭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '金额（CNY）'), '30');
    await tester.enterText(find.widgetWithText(TextField, '说明'), '午饭加蛋');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final after = state.ledger.getTransaction(tx.id);
    expect(after.amountMinor, 3000);
    expect(after.description, '午饭加蛋');
    expect(state.ledger.balance('wechat').minor, -3000);
    expect(state.ledger.auditFor(tx.id).map((e) => e.action), contains('transaction.update'));
  });

  test('forecast, savings math and anomaly questions answer directly', () async {
    final r = await state.say('每月存 3000 多久能攒到 2 万');
    expect(r.error, contains('7 个月'));
    final a = await state.say('这个月有没有异常支出');
    expect(a.error, contains('没有明显异常'));
    state.addManual({'type': 'expense', 'amount_minor': 1000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    final f = await state.say('照现在的花法月底还剩多少');
    expect(f.query, isNotNull);
    expect(f.query!.rows.map((x) => x.key), contains('projected'));
  });

  test('local-only switch blocks cloud endpoints; anthropic type builds; redact flag persists', () async {
    await state.saveSettings(const Settings(baseUrl: 'https://api.openai.com/v1', model: 'gpt', apiKey: 'k', localOnly: true));
    expect(state.hasModel, isFalse);
    await state.saveSettings(const Settings(baseUrl: 'http://192.168.1.2:11434/v1', model: 'qwen', localOnly: true));
    expect(state.hasModel, isTrue);
    await state.saveSettings(const Settings(baseUrl: 'https://api.anthropic.com/v1', model: 'claude', apiKey: 'k', providerType: 'anthropic'));
    expect(state.hasModel, isTrue);
    expect(state.settings.redact, isTrue);
  });
}

class _FakeChat extends ChatProvider {
  final String out;
  _FakeChat(this.out);
  @override
  String get name => 'fake';
  @override
  String get model => 'fake-model';
  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async =>
      ChatResult(text: out, model: model, latency: Duration.zero);
}
