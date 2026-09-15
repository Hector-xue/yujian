import 'dart:async';

import 'package:flutter/widgets.dart' hide Intent;
import 'package:interpreter/interpreter.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:notification_templates/notification_templates.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';
import 'package:query_dsl/query_dsl.dart';
import 'package:sync_client/sync_client.dart';

import 'notifications/notification_source.dart';
import 'notifications/share_source.dart';
import 'settings_store.dart';

/// 全局状态：账本 + 解析器 + 查询引擎。页面只通过这里读写，变更后 notify 刷新。
class AppState extends ChangeNotifier {
  final Ledger ledger;
  final QueryEngine engine;
  final SettingsStore settingsStore;
  final NotificationSource notifications;
  TemplateMatcher matcher = TemplateMatcher();
  StreamSubscription<NotificationEvent>? _liveSub;
  HybridInterpreter interpreter = HybridInterpreter();
  VisionInterpreter? vision;
  SyncClient? sync;
  String? lastSyncNote;
  /// 分享进来的内容，由对话页消费（消费后置 null）。
  SharedItem? pendingShare;
  final ShareSource share = ShareSource();
  Settings settings = const Settings();
  PersonaPack persona = builtinPersonas.first;
  PersonaReplier replier = PersonaReplier(builtinPersonas.first);

  AppState(this.ledger, {SettingsStore? settingsStore, NotificationSource? notifications})
      : engine = QueryEngine(ledger),
        settingsStore = settingsStore ?? MemorySettingsStore(),
        notifications = notifications ?? FakeNotificationSource();

  /// 读设置并按它装配解析器与人格。启动时和保存设置后各调一次。
  Future<void> loadSettings() async {
    settings = await settingsStore.load();
    _apply();
  }

  Future<void> saveSettings(Settings s) async {
    settings = s;
    await settingsStore.save(s);
    _apply();
  }

  void _apply() {
    final cfg = settings.providerConfig;
    final ChatProvider? p = cfg == null ? null : (cfg.type == ProviderType.anthropic ? AnthropicProvider(cfg) : OpenAICompatProvider(cfg));
    interpreter = HybridInterpreter(llm: p == null ? null : LLMInterpreter(p));
    vision = p == null ? null : VisionInterpreter(p);
    final custom = settings.customPersona;
    persona = custom != null && custom['id'] == settings.personaId ? PersonaPack.fromJson(custom) : personaById(settings.personaId);
    replier = PersonaReplier(persona, provider: p);
    final userTemplates = <NotificationTemplate>[];
    for (final t in settings.userTemplates) {
      try {
        userTemplates.add(NotificationTemplate.fromJson(t));
      } catch (_) {
        // 坏模板跳过，不拖垮其他
      }
    }
    matcher = TemplateMatcher(userTemplates: userTemplates);
    sync = settings.syncConfigured ? SyncClient(ledger, SyncConfig(baseUrl: settings.syncUrl!, token: settings.syncToken!)) : null;
    notifyListeners();
  }

  bool get hasModel => settings.providerConfig != null;

  /// 首次启动：默认分类 + 三个常用账户。
  void bootstrap() {
    ledger.seedDefaultCategories();
    if (ledger.listAccounts(includeArchived: true).isEmpty) {
      ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY');
      ledger.createAccount(id: 'alipay', name: '支付宝', type: AccountType.eWallet, currency: 'CNY');
      ledger.createAccount(id: 'cash', name: '现金', type: AccountType.cash, currency: 'CNY');
    }
  }

  void touch() => notifyListeners();

  /// 周期账单到期 → 草稿进收件箱。启动和新增周期项时调用。
  int generateRecurring() {
    final n = ledger.recurring.generateDue(today: _today(), tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes).length;
    if (n > 0) notifyListeners();
    return n;
  }

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> startShare() async {
    final first = await share.initial();
    if (first != null) {
      pendingShare = first;
      notifyListeners();
    }
    share.stream.listen((item) {
      pendingShare = item;
      notifyListeners();
    });
  }

  SharedItem? takeShare() {
    final s = pendingShare;
    pendingShare = null;
    return s;
  }

  // -------------------------------------------------------------------- 同步

  /// 一轮同步；失败不抛，记到 lastSyncNote 给 UI 看。
  Future<SyncReport?> syncNow() async {
    final c = sync;
    if (c == null) return null;
    try {
      final r = await c.sync();
      lastSyncNote = '${DateTime.now().toIso8601String().substring(11, 16)} ${r.toString()}';
      notifyListeners();
      return r;
    } on SyncException catch (e) {
      lastSyncNote = '同步失败：${e.message}';
      notifyListeners();
      return null;
    }
  }

  // ------------------------------------------------------------ 自动记账

  /// 启动：把 App 关着时攒下的通知吃掉，再订阅实时流。
  Future<int> startNotifications() async {
    if (!settings.notificationsWanted) return 0;
    final n = ingestNotifications(await notifications.drain());
    _liveSub ??= notifications.live.listen((e) => ingestNotifications([e]));
    return n;
  }

  /// 通知 → 模板抽取 → 草稿；按模式决定是否自动落账。返回新草稿/入账数。
  int ingestNotifications(List<NotificationEvent> events) {
    if (events.isEmpty) return 0;
    final ctx = context();
    final rule = interpreter.rule;
    var n = 0;
    for (final e in events) {
      final x = matcher.extract(e);
      if (x.ignored) continue;
      final accountId = (x.accountHint == null ? null : rule.matchAccount(x.accountHint!, ctx)) ?? ctx.defaultAccountId;
      final type = x.direction == 'income' ? 'income' : (x.direction == 'transfer' ? 'transfer' : 'expense');
      final kind = type == 'income' ? 'income' : 'expense';
      final categoryId = type == 'transfer' ? null : rule.guessCategory('${x.merchant ?? ''} ${e.text}', ctx, kind);
      final payload = <String, Object?>{
        'type': type,
        'amount_minor': x.amountMinor,
        'currency': x.currency,
        'account_id': accountId,
        if (type != 'transfer') 'category_id': categoryId,
        'merchant': x.merchant,
        'description': x.merchant ?? (e.title ?? e.packageName),
        'occurred_at': OccurredAt(DateTime.fromMillisecondsSinceEpoch(e.postedAtMs), DateTime.now().timeZoneOffset.inMinutes).toIso8601String(),
        'metadata': {'notification': {'package': e.packageName, 'title': e.title, 'text': e.text, 'template': x.templateId}},
      };
      final drafts = ledger.propose(
        [DraftInput(payload: payload, confidence: x.confidence, eventFingerprint: x.fingerprint, fingerprintIsExact: x.fingerprintIsExact)],
        source: Source.notification,
        actor: Actor.automation,
        interpreter: 'notification:${x.templateId}',
      );
      if (drafts.isEmpty) continue; // 精确指纹重复
      n++;
      final d = drafts.single;
      final auto = switch (settings.automationMode) {
        AutomationMode.confirm => false,
        AutomationMode.smart => d.missingFields.isEmpty && d.possibleDuplicateOf == null && x.confidence >= 0.85 && categoryId != null && x.accountHint != null,
        AutomationMode.silent => d.missingFields.isEmpty && d.possibleDuplicateOf == null,
      };
      if (auto) {
        try {
          ledger.commit(d.id);
        } on LedgerException {
          // 留在收件箱
        }
      }
    }
    if (n > 0) notifyListeners();
    return n;
  }

  /// 用户粘贴一段通知文案试模板（也是贡献模板的入口）。
  Extraction tryTemplate(String packageName, String? title, String text) =>
      matcher.extract(NotificationEvent(packageName: packageName, title: title, text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch));

  @override
  void dispose() {
    _liveSub?.cancel();
    super.dispose();
  }

  List<Anomaly> anomaliesThisMonth() {
    final now = DateTime.now();
    return detectAnomalies(ledger, from: '${now.year}-${now.month.toString().padLeft(2, '0')}-01', to: _today());
  }

  List<BudgetStatus> budgetAlerts() => ledger.budgets.statuses(today: _today()).where((s) => s.overAlert).toList();

  List<Account> get accounts => ledger.listAccounts();
  List<Category> get categories => ledger.listCategories();
  List<Draft> get inbox => ledger.listDrafts(status: DraftStatus.pending);

  InterpretContext context() {
    final accs = accounts;
    return InterpretContext(
      now: DateTime.now(),
      tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      defaultAccountId: accs.isEmpty ? null : accs.first.id,
      accounts: [for (final a in accs) AccountRef(id: a.id, name: a.name, currency: a.currency)],
      categories: [for (final c in categories) CategoryRef(id: c.id, name: c.name, kind: c.kind.db, parentId: c.parentId)],
      merchantMap: {for (final m in ledger.memory.all(limit: 300)) m.key: (categoryId: m.categoryId, accountId: m.accountId)},
      recentTransactions: [
        for (final t in ledger.listTransactions(limit: 20))
          RecentTransaction(id: t.id, amountMinor: t.amountMinor, currency: t.currency, localDate: t.occurredAt.localDate, categoryId: t.categoryId, description: t.description),
      ],
    );
  }

  /// 一句话 → 解析 → 草稿进收件箱（不落账）。返回解析结果与建立的草稿。
  Future<({InterpretResult result, List<Draft> drafts, QueryResult? query, String? error})> say(String text) async {
    // 周期账单 / 预算 的问法不进 Query DSL（它们不是交易聚合），直接答
    if (RegExp('固定账单|周期账单|订阅|每个月.*(要交|要付|固定)').hasMatch(text) && RegExp('哪些|多少|什么|有没有').hasMatch(text)) {
      final items = ledger.recurring.list();
      final lines = items.map((r) => '${r.name} ${Money(r.template['amount_minor'] as int, r.template['currency'] as String)}，下次 ${r.nextDue}').join('；');
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: items.isEmpty ? '还没有设置周期账单（更多 → 周期账单）' : '固定账单 ${items.length} 项：$lines');
    }
    // "每月存 3000 多久能攒到 2 万"：纯算术，不碰账本
    final save = RegExp(r'(每月|每个月|一个月)\s*(存|攒|省)\s*([\d.]+)\s*(万|k|K|千)?').firstMatch(text);
    final goal = RegExp(r'(攒到|存到|存够|攒够|凑够|达到)\s*([\d.]+)\s*(万|k|K|千)?').firstMatch(text);
    if (save != null && goal != null) {
      double num(String v, String? unit) => double.parse(v) * (unit == '万' ? 10000 : (unit == null ? 1 : 1000));
      final monthly = num(save.group(3)!, save.group(4));
      final target = num(goal.group(2)!, goal.group(3));
      if (monthly > 0) {
        final months = (target / monthly).ceil();
        return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: '每月存 ${Money((monthly * 100).round(), 'CNY').toDecimalString()}，攒到 ${Money((target * 100).round(), 'CNY').toDecimalString()} 需要 $months 个月（${(months / 12).toStringAsFixed(1)} 年）。');
      }
    }
    if (RegExp('异常|不正常|反常|比平时|花得多|花多了|大额').hasMatch(text)) {
      final now = DateTime.now();
      final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      final a = detectAnomalies(ledger, from: from, to: _today());
      final lines = a.take(5).map((x) => '${x.tx.description ?? categoryName(x.tx.categoryId)} ${Money(x.tx.amountMinor, x.tx.currency)}（${x.tx.occurredAt.localDate.substring(5)}，是${x.basis == 'category' ? '同类' : '平时'}中位数的 ${x.ratio.toStringAsFixed(1)} 倍）').join('；');
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: a.isEmpty ? '这个月没有明显异常的支出。' : '这个月 ${a.length} 笔明显高于平时：$lines');
    }
    if (RegExp('预算').hasMatch(text) && RegExp('还剩|剩多少|超了|怎么样|多少').hasMatch(text)) {
      final st = ledger.budgets.statuses(today: _today());
      final lines = st.map((s) => '${s.budget.name} 已用 ${Money(s.spentMinor, s.budget.currency)} / ${Money(s.budget.amountMinor, s.budget.currency)}${s.exceeded ? '（已超）' : ''}').join('；');
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: st.isEmpty ? '还没有设置预算（更多 → 预算）' : lines);
    }
    // 脱敏只影响发给模型的那份；规则解析仍看原文（规则不出网）
    final r = await interpreter.interpret(text, context(), redactForModel: settings.redact ? redactForModel : null);
    switch (r.intent) {
      case Intent.query:
        try {
          final q = QueryDsl.fromJson(r.query!);
          return (result: r, drafts: const <Draft>[], query: engine.run(q), error: null);
        } on FormatException catch (e) {
          return (result: r, drafts: const <Draft>[], query: null, error: '查询无法执行：${e.message}');
        }
      case Intent.chat:
        return (result: r, drafts: const <Draft>[], query: null, error: null);
      case Intent.proposeTransactions:
      case Intent.proposeUpdate:
      case Intent.proposeVoid:
        final inputs = <DraftInput>[];
        for (final d in r.drafts) {
          final kind = d.payload['kind'];
          if (kind == 'update') {
            final patch = {...d.payload}..remove('kind')..remove('target_transaction_id');
            inputs.add(DraftInput(kind: DraftKind.update, targetTransactionId: d.payload['target_transaction_id'] as String, payload: patch, confidence: d.confidence));
          } else if (kind == 'void') {
            inputs.add(DraftInput(kind: DraftKind.void_, targetTransactionId: d.payload['target_transaction_id'] as String, payload: {'reason': d.payload['reason']}, confidence: d.confidence));
          } else {
            inputs.add(DraftInput(payload: d.payload, confidence: d.confidence));
          }
        }
        if (inputs.isEmpty) return (result: r, drafts: const <Draft>[], query: null, error: '识别到${_intentName(r.intent)}，但没定位到目标交易');
        final drafts = ledger.propose(inputs, source: Source.chat, interpreter: r.interpreter, modelUsed: r.modelUsed);
        notifyListeners();
        return (result: r, drafts: drafts, query: null, error: null);
    }
  }

  /// 截图 / 小票 → 草稿（source screenshot）。
  Future<({List<Draft> drafts, String? error, String? modelUsed})> sayImage(List<int> bytes, String mime, {String hint = ''}) async {
    final v = vision;
    if (v == null) return (drafts: const <Draft>[], error: '识别图片需要先配置模型（更多 → 模型与人格）', modelUsed: null);
    try {
      final r = await v.interpret([ImageInput(bytes, mime)], context(), hint: hint);
      if (r.drafts.isEmpty) return (drafts: const <Draft>[], error: '图里没认出交易', modelUsed: r.modelUsed);
      final drafts = ledger.propose([for (final d in r.drafts) DraftInput(payload: d.payload, confidence: d.confidence)], source: Source.screenshot, interpreter: 'vision', modelUsed: r.modelUsed);
      notifyListeners();
      return (drafts: drafts, error: null, modelUsed: r.modelUsed);
    } on UnsupportedError {
      return (drafts: const <Draft>[], error: '当前模型不支持看图', modelUsed: null);
    } on ProviderException catch (e) {
      return (drafts: const <Draft>[], error: '模型出错：${e.message}', modelUsed: null);
    }
  }

  static String _intentName(Intent i) => switch (i) {
        Intent.proposeUpdate => '修改',
        Intent.proposeVoid => '作废',
        _ => '记账',
      };

  Transaction commit(String draftId, {Map<String, Object?>? edits}) {
    final t = ledger.commit(draftId, edits: edits);
    notifyListeners();
    return t;
  }

  List<Transaction> commitGroup(String groupId) {
    final ts = ledger.commitGroup(groupId);
    notifyListeners();
    return ts;
  }

  void dismiss(String draftId) {
    ledger.dismiss(draftId);
    notifyListeners();
  }

  void dismissGroup(String groupId) {
    for (final d in ledger.listDrafts(groupId: groupId, status: DraftStatus.pending)) {
      ledger.dismiss(d.id);
    }
    notifyListeners();
  }

  /// 作废 = 建一条 void 草稿并立即确认（用户已在对话框里确认过原因）。
  void voidTransaction(String id, String reason) {
    final d = ledger.propose([DraftInput(kind: DraftKind.void_, targetTransactionId: id, payload: {'reason': reason})], source: Source.manual, actor: Actor.user).single;
    ledger.commit(d.id);
    notifyListeners();
  }

  /// 修改 = update 草稿 + 立即确认（编辑表单本身就是确认动作）。
  Transaction updateTransaction(String id, Map<String, Object?> patch) {
    final d = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: id, payload: patch)], source: Source.manual, actor: Actor.user).single;
    final t = ledger.commit(d.id);
    notifyListeners();
    return t;
  }

  /// 手动记账 = create 草稿 + 立即确认。
  Transaction addManual(Map<String, Object?> payload) {
    final d = ledger.propose([DraftInput(payload: payload)], source: Source.manual, actor: Actor.user).single;
    final t = ledger.commit(d.id);
    notifyListeners();
    return t;
  }

  Account addAccount({required String name, required AccountType type, required String currency, int initialBalanceMinor = 0}) {
    final a = ledger.createAccount(name: name, type: type, currency: currency, initialBalanceMinor: initialBalanceMinor);
    notifyListeners();
    return a;
  }

  Category addCategory({required String name, required CategoryKind kind, String? parentId}) {
    final c = ledger.createCategory(name: name, kind: kind, parentId: parentId);
    notifyListeners();
    return c;
  }

  /// 导入账单 CSV：解析 → 账户/分类映射 → 一组草稿进收件箱。返回统计。
  ({int drafts, int deduped, int problems, String? error}) importBillCsv(String text) {
    final List<ImportedRow> rows;
    try {
      rows = parseBillCsv(text, tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    } on FormatException catch (e) {
      return (drafts: 0, deduped: 0, problems: 0, error: e.message);
    }
    final ctx = context();
    final rule = interpreter.rule;
    final inputs = <DraftInput>[];
    var problems = 0;
    for (final r in rows) {
      if (r.problems.isNotEmpty) problems++;
      final kind = r.type == 'income' ? 'income' : 'expense';
      final text = [r.categoryHint, r.merchant, r.description].whereType<String>().join(' ');
      final categoryId = r.type == 'transfer' ? null : rule.guessCategory(text, ctx, kind);
      final accountId = (r.accountHint == null ? null : rule.matchAccount(r.accountHint!, ctx)) ?? ctx.defaultAccountId;
      inputs.add(importedRowToDraft(r, accountId: accountId, categoryId: categoryId));
    }
    final drafts = ledger.propose(inputs, source: Source.import_, actor: Actor.automation, interpreter: 'import');
    notifyListeners();
    return (drafts: drafts.length, deduped: inputs.length - drafts.length, problems: problems, error: null);
  }

  /// 恢复备份：整库替换，之后重新装配（分类/账户变了）。
  int restoreBackup(Map<String, Object?> json) {
    final n = restoreFromJson(ledger, json);
    notifyListeners();
    return n;
  }

  String categoryName(String? id) => id == null ? '未分类' : (ledger.category(id)?.name ?? id);
  String accountName(String? id) => id == null ? '—' : (ledger.account(id)?.name ?? id);
}

/// InheritedNotifier 传递，不引第三方状态库。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
