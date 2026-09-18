import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' hide Intent;
import 'package:interpreter/interpreter.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:notification_templates/notification_templates.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';
import 'package:query_dsl/query_dsl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_client/sync_client.dart';

import 'companion/companion_memory.dart';
import 'db/db_file.dart';
import 'notifications/notification_source.dart';
import 'notifications/screenshot_source.dart';
import 'notifications/share_source.dart';
import 'platform/avatar_files_native.dart' if (dart.library.js_interop) 'platform/avatar_files_web.dart';
import 'platform/home_widget_bridge.dart';
import 'settings_store.dart';
import 'update/updater.dart';
import 'usage/usage_meter.dart';
import 'widgets/fmt.dart';

/// 全局状态：账本 + 解析器 + 查询引擎。页面只通过这里读写，变更后 notify 刷新。
class AppState extends ChangeNotifier {
  final Ledger ledger;
  final QueryEngine engine;
  final SettingsStore settingsStore;
  final NotificationSource notifications;
  final ScreenshotSource screenshots;
  TemplateMatcher matcher = TemplateMatcher();
  StreamSubscription<NotificationEvent>? _liveSub;
  HybridInterpreter interpreter = HybridInterpreter();
  VisionInterpreter? vision;
  /// 当前装配的模型（已包计量层）；null = 没配。
  ChatProvider? provider;
  SyncClient? sync;
  String? lastSyncNote;
  /// 分享进来的内容，由对话页消费（消费后置 null）。
  SharedItem? pendingShare;
  final ShareSource share = ShareSource();
  Settings settings = const Settings();
  PersonaPack persona = builtinPersonas.first;
  PersonaReplier replier = PersonaReplier(builtinPersonas.first);
  /// 陪聊：有模型才有；没模型时对话页用模板提示去配。
  CompanionReplier? companion;
  final CompanionMemory memory = CompanionMemory();
  /// token 用量记账（更多 → 用量与花费）。
  final UsageMeter usage = UsageMeter();

  /// 桌面小部件出口；测试与非 Android 传 null，就没有那个定时器。
  final HomeWidgetBridge? homeWidget;

  AppState(this.ledger, {SettingsStore? settingsStore, NotificationSource? notifications, ScreenshotSource? screenshots, this.homeWidget})
      : engine = QueryEngine(ledger),
        settingsStore = settingsStore ?? MemorySettingsStore(),
        notifications = notifications ?? FakeNotificationSource(),
        screenshots = screenshots ?? FakeScreenshotSource();

  /// 读设置并按它装配解析器与人格。启动时和保存设置后各调一次。
  Future<void> loadSettings() async {
    settings = await settingsStore.load();
    await memory.load();
    await usage.load();
    await _loadRecentNotices();
    try {
      autoHintDismissed = (await SharedPreferences.getInstance()).getBool('auto_hint_dismissed') ?? false;
    } catch (_) {}
    _apply();
  }

  /// 首页「自动记账还没开」的提示卡：两条路都没开才显示；用户关掉后不再出现。
  bool autoHintDismissed = false;
  bool get showAutoHint => notifications.supported && !autoHintDismissed && !settings.notificationsWanted && !settings.screenWanted && !settings.screenshotWanted;

  Future<void> dismissAutoHint() async {
    autoHintDismissed = true;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool('auto_hint_dismissed', true);
    } catch (_) {}
  }

  Future<void> saveSettings(Settings s) async {
    settings = s;
    await settingsStore.save(s);
    _apply();
  }

  // ------------------------------------------------------------ 人格 / 头像

  /// 新建或覆盖一个自定义人格包（按 id）；[select] 时顺手切过去。
  Future<void> upsertCustomPersona(Map<String, Object?> pack, {bool select = true}) async {
    final id = pack['id'] as String;
    final list = [...settings.customPersonas.where((c) => c['id'] != id), pack];
    await saveSettings(settings.copyWith(customPersonas: list, personaId: select ? id : null));
  }

  /// 删自定义人格；正在用它就退回极简助手；它的头像文件一起删。
  Future<void> removeCustomPersona(String id) async {
    final avatars = Map<String, String>.from(settings.personaAvatars);
    final path = avatars.remove(id);
    if (path != null) await deleteAvatarImage(path);
    await saveSettings(settings.copyWith(
      customPersonas: settings.customPersonas.where((c) => c['id'] != id).toList(),
      personaAvatars: avatars,
      personaId: settings.personaId == id ? builtinPersonas.first.id : null,
    ));
  }

  /// 给某个人格换头像：[bytes] 为 null = 恢复默认 emoji。
  Future<void> setPersonaAvatar(String personaId, Uint8List? bytes, {String ext = 'jpg'}) async {
    final avatars = Map<String, String>.from(settings.personaAvatars);
    final old = avatars.remove(personaId);
    if (bytes == null) {
      if (old != null) await deleteAvatarImage(old);
    } else {
      final path = await saveAvatarImage(personaId, bytes, ext);
      if (path != null) avatars[personaId] = path;
    }
    await saveSettings(settings.copyWith(personaAvatars: avatars));
  }

  void _apply() {
    final cfg = settings.providerConfig;
    // 所有对话 / 看图调用都包一层计量，用量页才有数
    final ChatProvider? p = cfg == null ? null : MeteredProvider(cfg.type == ProviderType.anthropic ? AnthropicProvider(cfg) : OpenAICompatProvider(cfg), onUsage: usage.record);
    provider = p;
    interpreter = HybridInterpreter(llm: p == null ? null : LLMInterpreter(p));
    vision = p == null ? null : VisionInterpreter(p);
    final custom = settings.customPersonaById(settings.personaId);
    persona = custom != null ? PersonaPack.fromJson(custom) : personaById(settings.personaId);
    replier = PersonaReplier(persona, provider: p, memory: () => memory.lines);
    companion = p == null ? null : CompanionReplier(persona, p);
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

  // ---------------------------------------------------------------- 更新
  ReleaseInfo? availableUpdate;
  bool updatePrompted = false;

  /// 启动时最多一天查一次；「检查更新」按钮 force。被跳过的版本不再弹。
  Future<ReleaseInfo?> checkUpdate({bool force = false}) async {
    final p = await SharedPreferences.getInstance();
    final last = p.getInt('update_last_check') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - last < 24 * 3600 * 1000) return availableUpdate;
    final r = await Updater.check();
    await p.setInt('update_last_check', now);
    if (r == null || !r.isNewer) {
      availableUpdate = null;
      notifyListeners();
      return null;
    }
    if (!force && p.getString('update_skipped') == r.version) return null;
    availableUpdate = r;
    notifyListeners();
    return r;
  }

  Future<void> skipUpdate(String version) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('update_skipped', version);
    availableUpdate = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 小部件
  Timer? _widgetTimer;

  /// 任何账本变化都会 notify；小部件跟着刷，但合并到 1 秒一次。
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (homeWidget == null) return;
    _widgetTimer?.cancel();
    _widgetTimer = Timer(const Duration(seconds: 1), pushHomeWidget);
  }

  /// 本月支出 / 收入 / 余额（CNY）推给桌面小部件。
  Future<void> pushHomeWidget() async {
    final w = homeWidget;
    if (w == null) return;
    try {
      final now = DateTime.now();
      final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      final last = DateTime(now.year, now.month + 1, 0).day;
      final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${last.toString().padLeft(2, '0')}';
      int cny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
      final expense = cny(engine.run(QueryDsl(timeRange: DateRange(from, to))).rows);
      final income = cny(engine.run(QueryDsl(types: const [TransactionType.income], timeRange: DateRange(from, to))).rows);
      final balance = ledger.balances().values.where((m) => m.currency == 'CNY').fold(0, (a, m) => a + m.minor);
      final today = _today();
      final todayExp = cny(engine.run(QueryDsl(timeRange: DateRange(today, today))).rows);
      final latest = ledger.listTransactions(limit: 1);
      final recent = latest.isEmpty ? '还没有记录，点「记一笔」开始' : '最近：${latest.first.description ?? categoryName(latest.first.categoryId)} ${fmtSigned(latest.first)} · ${latest.first.occurredAt.localDate.substring(5).replaceFirst('-', '/')}';
      // 4×4 日历：本月逐日支出 / 收入（分），按日序逗号分隔，缺的天是 0
      final expByDay = List<int>.filled(last, 0);
      final incByDay = List<int>.filled(last, 0);
      void fill(List<int> into, List<QueryRow> rows) {
        for (final r in rows) {
          final d = int.tryParse(r.key.length >= 10 ? r.key.substring(8, 10) : r.key) ?? 0;
          if (d >= 1 && d <= last && r.currency == 'CNY') into[d - 1] += r.valueMinor;
        }
      }
      fill(expByDay, engine.run(QueryDsl(timeRange: DateRange(from, to), groupBy: GroupBy.day, limit: 62)).rows);
      fill(incByDay, engine.run(QueryDsl(types: const [TransactionType.income], timeRange: DateRange(from, to), groupBy: GroupBy.day, limit: 62)).rows);
      await w.update(
        balance: fmtMoney(balance, 'CNY'),
        expense: fmtMoney(expense, 'CNY'),
        income: fmtMoney(income, 'CNY'),
        month: '${now.month} 月',
        recent: recent,
        today: fmtMoney(todayExp, 'CNY'),
        calYm: from.substring(0, 7),
        calExp: expByDay.join(','),
        calInc: incByDay.join(','),
      );
    } catch (_) {}
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
    // 原生侧的「支付页识别」开关每次启动都跟 App 设置对齐：它只在拨开关那一刻写过一次，清数据 / 换机 / 旧版本升上来都可能对不上，
    // 对不上就是服务绑着但什么都不做，且无从察觉
    await notifications.setScreenWanted(settings.screenWanted);
    if (!settings.notificationsWanted && !settings.screenWanted) return 0;
    final n = ingestNotifications(await notifications.drain());
    _liveSub ??= notifications.live.listen((e) => ingestNotifications([e]));
    return n;
  }

  /// 最近收到的原始通知（环形 30 条，含没认出来的）：「教它认一种通知」从这里选例子，不用用户手抄文案。
  final List<RecentNotice> recentNotices = [];
  static const _recentNoticesCap = 30;

  Future<void> _loadRecentNotices() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('recent_notices');
      if (raw == null) return;
      recentNotices
        ..clear()
        ..addAll([for (final j in jsonDecode(raw) as List) RecentNotice.fromJson(j as Map<String, Object?>)]);
    } catch (_) {
      // 坏数据丢掉，不影响启动
    }
  }

  void _remember(NotificationEvent e, Extraction x) {
    recentNotices.insert(0, RecentNotice(packageName: e.packageName, title: e.title, text: e.text, postedAtMs: e.postedAtMs, templateId: x.templateId, usable: x.usable && !x.ignored));
    if (recentNotices.length > _recentNoticesCap) recentNotices.removeRange(_recentNoticesCap, recentNotices.length);
  }

  Future<void> _saveRecentNotices() async {
    try {
      await (await SharedPreferences.getInstance()).setString('recent_notices', jsonEncode([for (final n in recentNotices) n.toJson()]));
    } catch (_) {}
  }

  /// 通知 → 模板抽取 → 草稿；按模式决定是否自动落账。返回新草稿/入账数。
  int ingestNotifications(List<NotificationEvent> events) {
    if (events.isEmpty) return 0;
    final ctx = context();
    final rule = interpreter.rule;
    var n = 0;
    for (final e in events) {
      final x = matcher.extract(e);
      _remember(e, x);
      // 认不出金额/方向的（验证码、聊天消息之类）不进收件箱：那不是账
      if (x.ignored || !x.usable) continue;
      final accountId = (x.accountHint == null ? null : rule.matchAccount(x.accountHint!, ctx)) ?? ctx.defaultAccountId;
      final type = x.direction == 'income' ? 'income' : (x.direction == 'transfer' ? 'transfer' : 'expense');
      final kind = type == 'income' ? 'income' : 'expense';
      final guessed = type == 'transfer' ? null : rule.guessCategory('${x.merchant ?? ''} ${e.text}', ctx, kind);
      // 猜不出分类落到「其他」，照样能记；智能模式仍要求真猜中才自动入账
      final categoryId = type == 'transfer' ? null : (guessed ?? ctx.fallbackCategoryId(kind));
      final payload = <String, Object?>{
        'type': type,
        'amount_minor': x.amountMinor,
        'currency': x.currency,
        'account_id': accountId,
        if (type != 'transfer') 'category_id': categoryId,
        'merchant': x.merchant,
        'description': x.merchant ?? (e.title ?? e.packageName),
        'occurred_at': OccurredAt(DateTime.fromMillisecondsSinceEpoch(e.postedAtMs), DateTime.now().timeZoneOffset.inMinutes).toIso8601String(),
        'metadata': {'notification': {'package': e.packageName, 'title': e.title, 'text': e.text, 'template': x.templateId, if (e.source != null) 'source': e.source}},
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
        AutomationMode.smart => d.missingFields.isEmpty && d.possibleDuplicateOf == null && x.confidence >= 0.85 && guessed != null && x.accountHint != null,
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
    unawaited(_saveRecentNotices()); // 一批只落一次盘（启动 drain 可能几百条）
    if (n > 0) notifyListeners();
    return n;
  }

  // ------------------------------------------------------------ 截图自动记账

  /// 最近处理过的截图（环形 20 条）：给自动记账页看"哪张记了、哪张忽略了、为什么"。
  final List<ScreenshotOutcome> screenshotLog = [];
  static const _screenshotLogCap = 20;
  StreamSubscription<void>? _shotSub;
  Future<void>? _shotRun; // 正在跑的一批，串行处理，别两批同时调模型

  Future<void> _loadScreenshotLog() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('screenshot_log');
      if (raw == null) return;
      screenshotLog
        ..clear()
        ..addAll([for (final j in jsonDecode(raw) as List) ScreenshotOutcome.fromJson((j as Map).cast<String, Object?>())]);
    } catch (_) {}
  }

  Future<void> _saveScreenshotLog() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('screenshot_log', jsonEncode([for (final o in screenshotLog) o.toJson()]));
    } catch (_) {}
  }

  /// 启动：开关开着就把队列吃掉 + 补扫上次检查之后的截图，再订阅实时通知。
  Future<int> startScreenshots() async {
    await _loadScreenshotLog();
    await screenshots.setWanted(settings.screenshotWanted);
    if (!settings.screenshotWanted) return 0;
    final p = await SharedPreferences.getInstance();
    await screenshots.catchUp(p.getInt('screenshot_checked_at') ?? DateTime.now().millisecondsSinceEpoch);
    await p.setInt('screenshot_checked_at', DateTime.now().millisecondsSinceEpoch);
    _shotSub ??= screenshots.live.listen((_) => drainScreenshots());
    return drainScreenshots();
  }

  /// 打开 / 关闭截图自动记账：开的时候要相册权限；拿不到就不开。返回最终状态。
  Future<bool> setScreenshotWanted(bool v) async {
    if (v) {
      final st = await screenshots.status();
      if (!st.permitted && !await screenshots.requestPermission()) return false;
    }
    await saveSettings(settings.copyWith(screenshotWanted: v));
    await screenshots.setWanted(v);
    if (v) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('screenshot_checked_at', DateTime.now().millisecondsSinceEpoch);
      _shotSub ??= screenshots.live.listen((_) => drainScreenshots());
    } else {
      await _shotSub?.cancel();
      _shotSub = null;
    }
    return v;
  }

  /// 把原生队列里的截图逐张过一遍视觉模型。串行：上一批没跑完就接在后面。返回这批新生成的草稿 / 入账数。
  Future<int> drainScreenshots() {
    final prev = _shotRun;
    final run = () async {
      if (prev != null) await prev;
      final events = await screenshots.drain();
      return ingestScreenshots(events);
    }();
    _shotRun = run;
    return run;
  }

  /// 截图 → 视觉模型（严格模式：不是交易凭证就空） → 草稿；按自动记账模式决定是否直接入账。
  Future<int> ingestScreenshots(List<ScreenshotEvent> events) async {
    if (events.isEmpty) return 0;
    var n = 0;
    for (final e in events) {
      final v = vision;
      if (v == null) {
        _noteScreenshot(e, 'skipped', '没配置模型');
        continue;
      }
      final bytes = await screenshots.readImage(e.uri);
      if (bytes == null) {
        _noteScreenshot(e, 'skipped', '图已不在（被删了？）');
        continue;
      }
      try {
        final r = await v.interpret([ImageInput(bytes, 'image/jpeg')], context(), autoScan: true);
        if (r.drafts.isEmpty) {
          _noteScreenshot(e, 'ignored', '不是交易截图', modelUsed: r.modelUsed);
          continue;
        }
        final inputs = <DraftInput>[];
        for (var i = 0; i < r.drafts.length; i++) {
          final d = r.drafts[i];
          final payload = {...d.payload, 'metadata': {...?(d.payload['metadata'] as Map?)?.cast<String, Object?>(), 'screenshot': {'name': e.name, 'added_ms': e.addedMs}}};
          // 指纹按 截图 id + 第几笔：同一张图再扫到（观察者与补扫重叠）不会重复起草
          inputs.add(DraftInput(payload: payload, confidence: d.confidence, eventFingerprint: 'shot:${e.id}:$i', fingerprintIsExact: true));
        }
        final drafts = ledger.propose(inputs, source: Source.screenshot, actor: Actor.automation, interpreter: 'vision:auto', modelUsed: r.modelUsed);
        if (drafts.isEmpty) {
          _noteScreenshot(e, 'ignored', '这张图已经记过', modelUsed: r.modelUsed);
          continue;
        }
        var committed = 0;
        for (final d in drafts) {
          final auto = switch (settings.automationMode) {
            AutomationMode.confirm => false,
            AutomationMode.smart => d.missingFields.isEmpty && d.possibleDuplicateOf == null && (d.confidence ?? 0) >= 0.7,
            AutomationMode.silent => d.missingFields.isEmpty && d.possibleDuplicateOf == null,
          };
          if (!auto) continue;
          try {
            ledger.commit(d.id);
            committed++;
          } on LedgerException {
            // 留在收件箱
          }
        }
        n += drafts.length;
        final amounts = drafts.map((d) => fmtMoney((d.payload['amount_minor'] as num?)?.toInt() ?? 0, (d.payload['currency'] as String?) ?? 'CNY')).join(' / ');
        _noteScreenshot(e, committed == drafts.length ? 'recorded' : 'inbox', committed == drafts.length ? '已记 $amounts' : '${drafts.length} 笔进收件箱${committed > 0 ? '（$committed 笔已记）' : ''} $amounts', modelUsed: r.modelUsed);
      } on UnsupportedError {
        _noteScreenshot(e, 'error', '当前模型不支持看图');
      } on ProviderException catch (ex) {
        _noteScreenshot(e, 'error', '模型出错：${ex.message}');
      } catch (ex) {
        _noteScreenshot(e, 'error', '$ex');
      }
    }
    unawaited(_saveScreenshotLog());
    if (n > 0) {
      notifyListeners();
      unawaited(pushHomeWidget());
    }
    return n;
  }

  void _noteScreenshot(ScreenshotEvent e, String outcome, String detail, {String? modelUsed}) {
    screenshotLog.insert(0, ScreenshotOutcome(name: e.name, atMs: DateTime.now().millisecondsSinceEpoch, outcome: outcome, detail: detail, modelUsed: modelUsed));
    if (screenshotLog.length > _screenshotLogCap) screenshotLog.removeRange(_screenshotLogCap, screenshotLog.length);
    unawaited(screenshots.log({'what': outcome, 'name': e.name, 'detail': detail}));
  }

  /// 用户粘贴一段通知文案试模板（也是贡献模板的入口）。
  Extraction tryTemplate(String packageName, String? title, String text) =>
      matcher.extract(NotificationEvent(packageName: packageName, title: title, text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch));

  @override
  void dispose() {
    _liveSub?.cancel();
    _shotSub?.cancel();
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

  /// 给陪聊层看的几行数字：今天 / 本月支出收入、预算、最近几笔、待确认。模型只能转述这些，别的编不出来。
  String ledgerBrief() {
    try {
      final now = DateTime.now();
      final today = _today();
      final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      final last = DateTime(now.year, now.month + 1, 0).day;
      final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${last.toString().padLeft(2, '0')}';
      int cny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
      final todayExp = engine.run(QueryDsl(timeRange: DateRange(today, today)));
      final monthExp = cny(engine.run(QueryDsl(timeRange: DateRange(from, to))).rows);
      final monthInc = cny(engine.run(QueryDsl(types: const [TransactionType.income], timeRange: DateRange(from, to))).rows);
      final byCat = engine.run(QueryDsl(timeRange: DateRange(from, to), groupBy: GroupBy.category, limit: 3)).rows;
      final recent = ledger.listTransactions(limit: 3);
      final budgets = ledger.budgets.statuses(today: today);
      final lines = <String>[
        '今天支出 ${fmtMoney(cny(todayExp.rows), 'CNY')}（${todayExp.matchedCount} 笔）',
        '本月支出 ${fmtMoney(monthExp, 'CNY')}，本月收入 ${fmtMoney(monthInc, 'CNY')}',
        if (byCat.isNotEmpty) '本月花得最多：${byCat.map((r) => '${r.label} ${fmtMoney(r.valueMinor, r.currency)}').join('、')}',
        for (final b in budgets.take(3)) '预算「${b.budget.name}」已用 ${fmtMoney(b.spentMinor, b.budget.currency)} / ${fmtMoney(b.budget.amountMinor, b.budget.currency)}${b.exceeded ? '（已超）' : ''}',
        if (recent.isNotEmpty) '最近几笔：${recent.map((t) => '${t.occurredAt.localDate.substring(5).replaceFirst('-', '/')} ${t.description ?? categoryName(t.categoryId)} ${fmtSigned(t)}').join('；')}',
        if (inbox.isNotEmpty) '收件箱里还有 ${inbox.length} 条待确认',
        if (ledger.listTransactions(limit: 1).isEmpty) '账本还是空的，一笔都没记过',
      ];
      return lines.join('\n');
    } catch (_) {
      return '';
    }
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

  /// 用 SQLite 文件整库替换（原生端）。同步身份会被清掉，下次同步从头拉。
  Future<int> restoreSqlite(Uint8List bytes) async {
    final n = await restoreDatabase(ledger.database, bytes);
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
  static AppState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}

/// 一条最近收到的通知 + 当时的识别结果（只存文案，给「教它认一种通知」选例子）。
class RecentNotice {
  final String packageName;
  final String? title;
  final String text;
  final int postedAtMs;
  final String templateId; // ignore / none / 某模板
  final bool usable; // 当时是否认出了金额和方向
  const RecentNotice({required this.packageName, this.title, required this.text, required this.postedAtMs, required this.templateId, required this.usable});

  Map<String, Object?> toJson() => {'package': packageName, 'title': title, 'text': text, 'posted_at_ms': postedAtMs, 'template': templateId, 'usable': usable};
  factory RecentNotice.fromJson(Map<String, Object?> j) => RecentNotice(
        packageName: j['package'] as String,
        title: j['title'] as String?,
        text: (j['text'] as String?) ?? '',
        postedAtMs: (j['posted_at_ms'] as num?)?.toInt() ?? 0,
        templateId: (j['template'] as String?) ?? 'none',
        usable: j['usable'] == true,
      );
}

/// 一张截图的处理结果（只存文件名和结论，不存图）。outcome：recorded / inbox / ignored / skipped / error。
class ScreenshotOutcome {
  final String name;
  final int atMs;
  final String outcome;
  final String detail;
  final String? modelUsed;
  const ScreenshotOutcome({required this.name, required this.atMs, required this.outcome, required this.detail, this.modelUsed});

  Map<String, Object?> toJson() => {'name': name, 'at_ms': atMs, 'outcome': outcome, 'detail': detail, 'model': modelUsed};
  factory ScreenshotOutcome.fromJson(Map<String, Object?> j) => ScreenshotOutcome(
        name: (j['name'] as String?) ?? '',
        atMs: (j['at_ms'] as num?)?.toInt() ?? 0,
        outcome: (j['outcome'] as String?) ?? 'ignored',
        detail: (j['detail'] as String?) ?? '',
        modelUsed: j['model'] as String?,
      );
}
