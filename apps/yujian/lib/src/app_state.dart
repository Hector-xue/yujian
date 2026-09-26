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
import 'game/game_layer.dart';
import 'notifications/notification_source.dart';
import 'notifications/screenshot_ocr.dart';
import 'notifications/screenshot_source.dart';
import 'notifications/share_source.dart';
import 'platform/avatar_files_native.dart' if (dart.library.js_interop) 'platform/avatar_files_web.dart';
import 'platform/home_widget_bridge.dart';
import 'privacy/net_log.dart';
import 'settings_store.dart';
import 'support/support_config.dart';
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
  /// 截图自动记账用的两条模型路（标签不同，出网记录里分得清）：「发文字」档的文本模型、「发原图」档的看图模型。
  LLMInterpreter? shotLlm;
  VisionInterpreter? shotVision;
  /// 当前装配的模型（已包计量层）；null = 没配（含纯本地模式挡掉的情况）。
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
  /// 出网记录：每一次数据出手机都在这里留一行（更多 → 隐私 → 出网记录）。
  final NetLog netLog = NetLog();
  /// 财富游戏层（目标 / 可花的 / 等级 / 任务 / 成就 / 仪式）。数字全从账本推导。
  late final GameLayer game = GameLayer(this);
  /// 周任务生成 / 月度复盘润色用的模型（出网记录标 tasks）；null = 没模型或纯本地模式。
  ChatProvider? taskProvider;

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
    await netLog.load();
    await _loadRecentNotices();
    try {
      final p = await SharedPreferences.getInstance();
      autoHintDismissed = p.getBool('auto_hint_dismissed') ?? false;
      _anomaliesDismissed.addAll(p.getStringList('anomalies_dismissed') ?? const []);
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

  /// 自定义全局背景：[bytes] 为 null = 移除。
  Future<void> setBackground(Uint8List? bytes, {String ext = 'jpg'}) async {
    final old = settings.backgroundImage;
    if (old != null) await deleteAvatarImage(old); // 同一套文件工具
    final path = bytes == null ? null : await saveBackgroundImage(bytes, ext);
    await saveSettings(settings.copyWith(backgroundImage: path ?? ''));
  }

  void _apply() {
    final cfg = settings.providerConfig;
    // 所有对话 / 看图调用都包一层计量：用量页才有数，出网记录才有行。
    // 每个消费方各包一层、打不同的用途标签，出网记录里能说清「这次是解析你的话 / 陪聊 / 看图 / 截图」。
    final ChatProvider? raw = cfg == null ? null : (cfg.type == ProviderType.anthropic ? AnthropicProvider(cfg) : OpenAICompatProvider(cfg));
    final host = hostOf(cfg?.baseUrl);
    ChatProvider? tagged(String purpose) => raw == null ? null : MeteredProvider(raw, purpose: purpose, onUsage: usage.record, onCall: (c) => netLog.recordCall(c, host: host, redacted: settings.redact));
    final p = tagged('interpret');
    provider = p;
    interpreter = HybridInterpreter(llm: p == null ? null : LLMInterpreter(p));
    final v = tagged('image');
    vision = v == null ? null : VisionInterpreter(v);
    final st = tagged('shot_text');
    shotLlm = st == null ? null : LLMInterpreter(st);
    final sv = tagged('shot_image');
    shotVision = sv == null ? null : VisionInterpreter(sv);
    final custom = settings.customPersonaById(settings.personaId);
    persona = custom != null ? PersonaPack.fromJson(custom) : personaById(settings.personaId);
    replier = PersonaReplier(persona, provider: tagged('reply'), memory: () => memory.lines);
    final cp = tagged('companion');
    companion = cp == null ? null : CompanionReplier(persona, cp);
    taskProvider = tagged('tasks');
    final userTemplates = <NotificationTemplate>[];
    for (final t in settings.userTemplates) {
      try {
        userTemplates.add(NotificationTemplate.fromJson(t));
      } catch (_) {
        // 坏模板跳过，不拖垮其他
      }
    }
    matcher = TemplateMatcher(userTemplates: userTemplates);
    sync = settings.syncActive ? SyncClient(ledger, SyncConfig(baseUrl: settings.syncUrl!, token: settings.syncToken!)) : null;
    notifyListeners();
  }

  bool get hasModel => settings.providerConfig != null;

  /// 纯本地模式一键开关。开：所有出网路径立刻失效（模型 / 云端语音 / 云转写 / 同步 / 自动版本检查）；配置本身保留，关掉就恢复。
  Future<void> setOfflineMode(bool on) => saveSettings(settings.copyWith(offlineMode: on));

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

  // ---------------------------------------------------------------- 支持余见

  /// 点了「支付宝 / 微信」付款按钮的时刻；之后 [SupportConfig.detectWindow] 内识别到一笔 ¥1 支出就算支持过。
  DateTime? supportPayTappedAt;
  void noteSupportPayTapped() => supportPayTappedAt = DateTime.now();

  bool get isSupporter => ledger.profile.supporterSince != null;

  /// 这次运行里是怎么记成支持者的（页面上道谢用；重启后为 null，日期本身在画像里）。
  String? supportMarkedVia;

  /// 更多页顶部那张卡要不要出现：没支持过、不在「30 天后再说」里、且用到一定程度（记满 30 笔或用满 14 天）。
  bool get supportPromptVisible {
    if (isSupporter) return false;
    final snooze = ledger.profile.supportSnoozeUntil;
    if (snooze != null && snooze.compareTo(_today()) > 0) return false;
    if (ledger.countTransactions() >= SupportConfig.minTransactions) return true;
    final first = ledger.firstRecordedAtMs();
    if (first == null) return false;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(first)).inDays >= SupportConfig.minDays;
  }

  /// 记成支持者：日期落在画像里（随同步走，换机重装不再问）；成就下一轮重算解锁「支持者」并在对话里道谢。
  /// [via]：manual（点了「我已支持」）/ screen（支付页识别到）/ notification（通知识别到）。
  void markSupporter({required String via}) {
    if (isSupporter) return;
    ledger.profile.supporterSince = _today();
    ledger.profile.supportSnoozeUntil = null;
    supportPayTappedAt = null;
    supportMarkedVia = via;
    notifyListeners();
  }

  void snoozeSupport() {
    final d = DateTime.now().add(const Duration(days: SupportConfig.snoozeDays));
    ledger.profile.supportSnoozeUntil = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    notifyListeners();
  }

  /// 通知 / 支付页识别到的一笔：刚点过付款按钮、金额正好是 ¥1 的支出 → 就是那笔支持。
  /// 只看时间窗 + 金额，不认收款方名字（微信 / 支付宝 / 通知 / 屏幕四条路的文案各不相同，认名字每条都得单独验；
  /// 点完「支持」十分钟内恰好另付一笔一块钱的概率极低，认错的后果也只是提醒关掉）。
  void _maybeSupportPayment(NotificationEvent e, Extraction x) {
    final t = supportPayTappedAt;
    if (t == null || isSupporter) return;
    if (DateTime.now().difference(t) > SupportConfig.detectWindow) {
      supportPayTappedAt = null;
      return;
    }
    if (x.ignored || x.amountMinor != SupportConfig.amountMinor || x.direction == 'income' || x.direction == 'refund') return;
    markSupporter(via: e.source == 'screen' ? 'screen' : 'notification');
  }

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

  /// 性能层（帧时间条）：更多页长按版本号切换，给用户截图定位卡顿用。
  bool perfOverlay = false;
  void togglePerfOverlay() {
    perfOverlay = !perfOverlay;
    notifyListeners();
  }

  /// 启动时最多一天查一次；「检查更新」按钮 force。被跳过的版本不再弹。
  /// 纯本地模式下不自动查（用户手动点「检查更新」才查）。每次查都进出网记录。
  Future<ReleaseInfo?> checkUpdate({bool force = false}) async {
    if (settings.offlineMode && !force) return null;
    final p = await SharedPreferences.getInstance();
    final last = p.getInt('update_last_check') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - last < 24 * 3600 * 1000) return availableUpdate;
    ReleaseInfo? r;
    try {
      r = await netLog.track(Updater.check, kind: 'update', purpose: 'check', host: hostOf(Updater.endpoint));
    } catch (_) {
      r = null;
    }
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
    game.markDirty(); // 指标 / 目标进度 / 成就在账本变化后重算一次（合并），页面只读缓存
    if (homeWidget == null) return;
    _widgetTimer?.cancel();
    _widgetTimer = Timer(const Duration(seconds: 1), pushHomeWidget);
  }

  /// 启动：结算旧周 / 生成本周任务候选 / 到期定存 / 发薪日 / 月末复盘，再算一遍指标。
  Future<void> startGame() async {
    try {
      await game.ensureWeek();
      await game.runRituals();
    } catch (_) {}
    await game.recompute();
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
      final balance = Wealth.cashOnHand(ledger); // 和首页「余额」同一口径：手头的钱，不含信用卡 / 贷款 / 投资
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
      // 4×2 目标小部件：可花的 + 前 3 个目标（还清了的还清目标不占位，和首页目标条同一个过滤）
      final m = game.enabled ? game.metrics : null;
      final goalRows = [
        for (final p in game.goals.where((p) => p.goal.kind != GoalKind.payoff || !p.reached).take(3))
          {
            'e': p.goal.emoji ?? '🎯',
            'n': p.goal.name,
            'p': (p.ratio * 100).round(),
            't': p.reached ? (p.goal.kind == GoalKind.payoff ? '还清了' : '攒够了') : '${p.goal.kind == GoalKind.payoff ? '还欠' : '还差'} ${fmtMoney(p.remainingMinor, p.goal.currency)}',
            's': '${p.goal.kind == GoalKind.payoff ? '已还' : '已攒'} ${fmtMoney(p.savedMinor, p.goal.currency)} / ${fmtMoney(p.targetMinor, p.goal.currency)}',
            'd': p.reached,
          },
      ];
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
        // 称号跟首页同一来源（游戏层关着 = 首页不显示 = 小部件也不显示）
        title: m?.title ?? '',
        disposable: m == null ? fmtMoney(balance, 'CNY') : fmtMoney(m.disposableMinor, 'CNY'),
        goals: game.enabled ? jsonEncode(goalRows) : '[]',
        net: fmtMoney(income - expense, 'CNY'), // 4×2 的第三格「结余」
      );
    } catch (_) {}
  }

  // -------------------------------------------------------------------- 同步

  /// 一轮同步；失败不抛，记到 lastSyncNote 给 UI 看。
  Future<SyncReport?> syncNow() async {
    final c = sync;
    if (c == null) return null;
    try {
      final r = await trackSync('sync', () => c.sync(), countOf: (r) => r.pushed + r.pulled);
      lastSyncNote = '${DateTime.now().toIso8601String().substring(11, 16)} ${r.toString()}';
      notifyListeners();
      return r;
    } on SyncException catch (e) {
      lastSyncNote = '同步失败：${e.message}';
      notifyListeners();
      return null;
    }
  }

  /// 同步页和启动同步都从这里过：成功失败都进出网记录。
  Future<T> trackSync<T>(String purpose, Future<T> Function() body, {int Function(T)? countOf, int Function(T)? bytesOf}) =>
      netLog.track(body, kind: 'sync', purpose: purpose, host: hostOf(settings.syncUrl), countOf: countOf, bytesOf: bytesOf);

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

  void _remember(NotificationEvent e, Extraction x, {bool drafted = false}) {
    recentNotices.insert(0, RecentNotice(packageName: e.packageName, title: e.title, text: e.text, postedAtMs: e.postedAtMs, templateId: x.templateId, usable: x.usable && !x.ignored, source: e.source, amountMinor: x.amountMinor, drafted: drafted));
    if (recentNotices.length > _recentNoticesCap) recentNotices.removeRange(_recentNoticesCap, recentNotices.length);
  }

  /// 支付页识别的近期去重：同一 App 同一金额 10 分钟内已经起草过一笔，就不再起草。
  /// 成功页按「完成」回到聊天页时，页面里还是那张凭证，原生侧只挡 2 分钟、指纹又按分钟桶，靠这层兜住；
  /// 窗口只有 10 分钟，半小时内两杯同价咖啡不会被吞。
  static const _screenDedupeWindow = Duration(minutes: 10);
  bool _recentlyDraftedFromScreen(NotificationEvent e, Extraction x) {
    if (e.source != 'screen' || x.amountMinor == null) return false;
    for (final n in recentNotices) {
      if (n.source != 'screen' || !n.drafted || n.packageName != e.packageName || n.amountMinor != x.amountMinor) continue;
      if ((e.postedAtMs - n.postedAtMs).abs() <= _screenDedupeWindow.inMilliseconds) return true;
    }
    return false;
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
      _maybeSupportPayment(e, x);
      // 认不出金额/方向的（验证码、聊天消息之类）不进收件箱：那不是账
      if (x.ignored || !x.usable) {
        _remember(e, x);
        continue;
      }
      if (_recentlyDraftedFromScreen(e, x)) {
        _remember(e, x);
        continue;
      }
      final accountId = (x.accountHint == null ? null : rule.matchAccount(x.accountHint!, ctx)) ?? ctx.defaultAccountId;
      final type = switch (x.direction) { 'income' => 'income', 'transfer' => 'transfer', 'refund' => 'refund', _ => 'expense' };
      final hasCategory = type == 'income' || type == 'expense';
      final kind = type == 'income' ? 'income' : 'expense';
      final guessed = hasCategory ? rule.guessCategory('${x.merchant ?? ''} ${e.text}', ctx, kind) : null;
      // 猜不出分类落到「其他」，照样能记；智能模式仍要求真猜中才自动入账
      final categoryId = hasCategory ? (guessed ?? ctx.fallbackCategoryId(kind)) : null;
      final postedAt = DateTime.fromMillisecondsSinceEpoch(e.postedAtMs);
      final payload = <String, Object?>{
        'type': type,
        'amount_minor': x.amountMinor,
        'currency': x.currency,
        'account_id': accountId,
        if (hasCategory) 'category_id': categoryId,
        // 退款冲减原来那笔支出：按商户 / 金额猜原单，猜不到留空，收件箱里让用户挑
        if (type == 'refund') 'refund_of_id': ledger.guessRefundOriginal(amountMinor: x.amountMinor!, currency: x.currency, merchant: x.merchant, at: postedAt),
        'merchant': x.merchant,
        'description': x.merchant ?? (e.title ?? e.packageName),
        'occurred_at': OccurredAt(postedAt, DateTime.now().timeZoneOffset.inMinutes).toIso8601String(),
        'metadata': {'notification': {'package': e.packageName, 'title': e.title, 'text': e.text, 'template': x.templateId, if (e.source != null) 'source': e.source}},
      };
      final drafts = ledger.propose(
        [DraftInput(payload: payload, confidence: x.confidence, eventFingerprint: x.fingerprint, fingerprintIsExact: x.fingerprintIsExact)],
        source: Source.notification,
        actor: Actor.automation,
        interpreter: 'notification:${x.templateId}',
      );
      if (drafts.isEmpty) {
        _remember(e, x); // 精确指纹重复
        continue;
      }
      _remember(e, x, drafted: true);
      n++;
      final d = drafts.single;
      final auto = switch (settings.automationMode) {
        AutomationMode.confirm => false,
        AutomationMode.smart => d.missingFields.isEmpty && d.possibleDuplicateOf == null && x.confidence >= 0.85 && (guessed != null || (type == 'refund' && payload['refund_of_id'] != null)) && x.accountHint != null,
        AutomationMode.silent => d.missingFields.isEmpty && d.possibleDuplicateOf == null,
      };
      if (auto) {
        try {
          unawaited(game.onIncomeCommitted(ledger.commit(d.id))); // 静默入账的工资也要触发发薪日仪式
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
  /// 截图 → 草稿。三档（settings.screenshotMode）：
  /// - local：本机 OCR + 规则，图和字都不出手机；认不出就丢；
  /// - text：本机先认，认不出时把 OCR 文字**脱敏后**发给文本模型（图始终不出手机）；
  /// - image：原图发给视觉模型（0.8.13 之前唯一的做法）。
  /// 三档都先在本机判「像不像一笔交易」：聊天、照片、网页在这一步就丢，连 text 档也不会碰到它们。
  Future<int> ingestScreenshots(List<ScreenshotEvent> events) async {
    if (events.isEmpty) return 0;
    var n = 0;
    final mode = settings.effectiveScreenshotMode;
    for (final e in events) {
      try {
        n += switch (mode) {
          'image' => await _ingestShotByImage(e),
          'text' => await _ingestShotLocally(e, thenText: true),
          _ => await _ingestShotLocally(e, thenText: false),
        };
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

  /// 本机 OCR + 规则；[thenText] 时本地认不出再把脱敏后的文字发给文本模型。
  Future<int> _ingestShotLocally(ScreenshotEvent e, {required bool thenText}) async {
    final lines = await screenshots.ocr(e.uri);
    if (lines == null) {
      _noteScreenshot(e, 'skipped', '这个平台没有本地识别（换「发原图」才能用）');
      return 0;
    }
    final shot = ScreenshotOcrParser.parse(lines, fallbackTime: DateTime.fromMillisecondsSinceEpoch(e.addedMs));
    if (!shot.looksLikeTransaction) {
      _noteScreenshot(e, 'ignored', '不是交易截图（本机判断，没上传）');
      return 0;
    }
    // 本地够硬就直接起草；「发文字」档下证据弱的（没标签、没 ¥ 的裸数字）交给模型再看一眼
    if (shot.usable && (!thenText || shot.confident || interpreter.llm == null)) {
      final (payload, guessed) = _localShotPayload(shot, fallback: DateTime.fromMillisecondsSinceEpoch(e.addedMs));
      return _proposeShot(e, [DraftInput(payload: payload, confidence: shot.confidence, eventFingerprint: 'shot:${e.id}:0', fingerprintIsExact: true)], interpreter: 'ocr:local', modelUsed: null, autoOk: guessed || payload['type'] == 'transfer' || (payload['type'] == 'refund' && payload['refund_of_id'] != null));
    }
    if (!thenText) {
      _noteScreenshot(e, 'ignored', '像是交易但本机没认出金额（可在自动记账页切到「本机认不出时发文字」）');
      return 0;
    }
    final llm = shotLlm;
    if (llm == null) {
      _noteScreenshot(e, 'skipped', settings.offlineMode ? '本机没认出；纯本地模式下不发给模型' : '本机没认出，且没配置模型');
      return 0;
    }
    // 只发文字，且先脱敏（卡号 / 手机号 / 订单号 / 邮箱打码）；图不出手机。
    // 直接走模型、不过规则解释器：OCR 的整页文字里常有「余额」「多少」这种词，规则会把它当成查询
    final text = settings.redact ? redactForModel(shot.text) : shot.text;
    final r = await llm.interpret('这是我截图上 OCR 出来的文字，请从中识别交易：\n$text', context());
    final inputs = [
      for (var i = 0; i < r.drafts.length; i++)
        if (r.drafts[i].payload['kind'] == null) DraftInput(payload: r.drafts[i].payload, confidence: r.drafts[i].confidence, eventFingerprint: 'shot:${e.id}:$i', fingerprintIsExact: true),
    ];
    if (inputs.isEmpty) {
      _noteScreenshot(e, 'ignored', '文字发给模型也没认出交易', modelUsed: r.modelUsed);
      return 0;
    }
    return _proposeShot(e, inputs, interpreter: 'ocr:text', modelUsed: r.modelUsed, autoOk: true);
  }

  /// 本机识别结果 → 草稿载荷（账户按提示匹配、分类按商户 / 全文猜、猜不中兜底「其他」）。返回 (载荷, 分类是不是猜中的)。
  (Map<String, Object?>, bool) _localShotPayload(LocalShot shot, {required DateTime fallback}) {
    final ctx = context();
    final rule = interpreter.rule;
    final accountId = (shot.accountHint == null ? null : rule.matchAccount(shot.accountHint!, ctx)) ?? ctx.defaultAccountId;
    final type = shot.direction!;
    final hasCategory = type == 'income' || type == 'expense';
    final kind = type == 'income' ? 'income' : 'expense';
    final guessed = hasCategory ? rule.guessCategory('${shot.merchant ?? ''} ${shot.text}', ctx, kind) : null;
    final categoryId = hasCategory ? (guessed ?? ctx.fallbackCategoryId(kind)) : null;
    final when = shot.occurredAt ?? fallback;
    return (
      <String, Object?>{
        'type': type,
        'amount_minor': shot.amountMinor,
        'currency': 'CNY',
        'account_id': accountId,
        if (hasCategory) 'category_id': categoryId,
        if (type == 'refund') 'refund_of_id': ledger.guessRefundOriginal(amountMinor: shot.amountMinor!, currency: 'CNY', merchant: shot.merchant, at: when),
        'merchant': shot.merchant,
        'description': shot.merchant ?? '截图记账',
        'occurred_at': OccurredAt(when, DateTime.now().timeZoneOffset.inMinutes).toIso8601String(),
      },
      guessed != null,
    );
  }

  /// 对话里「识别截图」在没有视觉模型时（纯本地模式 / 没配模型）走本机：OCR + 规则 → 草稿，图不出手机。
  /// 返回 null = 这个平台没有本机识别（只有 Android 有 ML Kit）。
  Future<({List<Draft> drafts, String? error, String? modelUsed})?> sayImageLocally(String path) async {
    if (!screenshots.supported) return null;
    final List<OcrLine>? lines;
    try {
      lines = await screenshots.ocr(Uri.file(path).toString());
    } catch (_) {
      return (drafts: const <Draft>[], error: '本机识别出错了，换一张试试', modelUsed: null);
    }
    if (lines == null) return null;
    final shot = ScreenshotOcrParser.parse(lines, fallbackTime: DateTime.now());
    if (!shot.looksLikeTransaction) return (drafts: const <Draft>[], error: '这张图不像交易截图（本机判断，没上传）', modelUsed: null);
    if (!shot.usable) return (drafts: const <Draft>[], error: '像是交易，但本机没认出金额。支付成功页 / 账单详情认得准，排版乱的小票认不出', modelUsed: null);
    final (payload, _) = _localShotPayload(shot, fallback: DateTime.now());
    final drafts = ledger.propose([DraftInput(payload: payload, confidence: shot.confidence)], source: Source.screenshot, interpreter: 'ocr:local');
    if (drafts.isEmpty) return (drafts: const <Draft>[], error: '这张图已经记过', modelUsed: null);
    notifyListeners();
    return (drafts: drafts, error: null, modelUsed: '本机识别');
  }

  /// 原图发给视觉模型。
  Future<int> _ingestShotByImage(ScreenshotEvent e) async {
    final v = shotVision;
    if (v == null) {
      _noteScreenshot(e, 'skipped', '没配置模型');
      return 0;
    }
    final bytes = await screenshots.readImage(e.uri);
    if (bytes == null) {
      _noteScreenshot(e, 'skipped', '图已不在（被删了？）');
      return 0;
    }
    final r = await v.interpret([ImageInput(bytes, 'image/jpeg')], context(), autoScan: true);
    if (r.drafts.isEmpty) {
      _noteScreenshot(e, 'ignored', '不是交易截图', modelUsed: r.modelUsed);
      return 0;
    }
    final inputs = <DraftInput>[];
    for (var i = 0; i < r.drafts.length; i++) {
      final d = r.drafts[i];
      // 指纹按 截图 id + 第几笔：同一张图再扫到（观察者与补扫重叠）不会重复起草
      inputs.add(DraftInput(payload: d.payload, confidence: d.confidence, eventFingerprint: 'shot:${e.id}:$i', fingerprintIsExact: true));
    }
    return _proposeShot(e, inputs, interpreter: 'vision:auto', modelUsed: r.modelUsed, autoOk: true);
  }

  /// 起草 + 按自动记账模式决定入不入账，并写处理记录。返回起草数。[autoOk] 为假时智能模式不自动入账（本地规则没猜中分类）。
  int _proposeShot(ScreenshotEvent e, List<DraftInput> inputs, {required String interpreter, required String? modelUsed, required bool autoOk}) {
    final withMeta = [
      for (final d in inputs)
        DraftInput(
          kind: d.kind,
          targetTransactionId: d.targetTransactionId,
          payload: {...d.payload, 'metadata': {...?(d.payload['metadata'] as Map?)?.cast<String, Object?>(), 'screenshot': {'name': e.name, 'added_ms': e.addedMs, 'how': interpreter}}},
          confidence: d.confidence,
          eventFingerprint: d.eventFingerprint,
          fingerprintIsExact: d.fingerprintIsExact,
        ),
    ];
    final drafts = ledger.propose(withMeta, source: Source.screenshot, actor: Actor.automation, interpreter: interpreter, modelUsed: modelUsed);
    if (drafts.isEmpty) {
      _noteScreenshot(e, 'ignored', '这张图已经记过', modelUsed: modelUsed);
      return 0;
    }
    var committed = 0;
    for (final d in drafts) {
      final auto = switch (settings.automationMode) {
        AutomationMode.confirm => false,
        AutomationMode.smart => autoOk && d.missingFields.isEmpty && d.possibleDuplicateOf == null && (d.confidence ?? 0) >= 0.7,
        AutomationMode.silent => d.missingFields.isEmpty && d.possibleDuplicateOf == null,
      };
      if (!auto) continue;
      try {
        unawaited(game.onIncomeCommitted(ledger.commit(d.id)));
        committed++;
      } on LedgerException {
        // 留在收件箱
      }
    }
    final amounts = drafts.map((d) => fmtMoney((d.payload['amount_minor'] as num?)?.toInt() ?? 0, (d.payload['currency'] as String?) ?? 'CNY')).join(' / ');
    final how = interpreter == 'ocr:local' ? '本机识别 · ' : '';
    _noteScreenshot(e, committed == drafts.length ? 'recorded' : 'inbox', '$how${committed == drafts.length ? '已记 $amounts' : '${drafts.length} 笔进收件箱${committed > 0 ? '（$committed 笔已记）' : ''} $amounts'}', modelUsed: modelUsed);
    return drafts.length;
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

  /// 首页「比平时高」用的：它是「刚发生的一笔，看一眼」的提醒，不是月报——只看最近 [homeAnomalyDays] 天，
  /// 划掉的按交易 id 记住不再出现（以前按整月算，1 号一笔大额能挂到月底）。
  static const homeAnomalyDays = 7;
  final Set<String> _anomaliesDismissed = {};
  List<Anomaly> homeAnomalies() {
    final from = DateTime.now().subtract(const Duration(days: homeAnomalyDays - 1));
    final fromDate = '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}';
    return [for (final a in detectAnomalies(ledger, from: fromDate, to: _today())) if (!_anomaliesDismissed.contains(a.tx.id)) a];
  }

  Future<void> dismissAnomaly(String txId) async {
    _anomaliesDismissed.add(txId);
    notifyListeners();
    try {
      // 只留最近 200 个 id，够覆盖 7 天窗口里出现过的
      final keep = _anomaliesDismissed.toList();
      await (await SharedPreferences.getInstance()).setStringList('anomalies_dismissed', keep.length > 200 ? keep.sublist(keep.length - 200) : keep);
    } catch (_) {}
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
          RecentTransaction(id: t.id, amountMinor: t.amountMinor, currency: t.currency, localDate: t.occurredAt.localDate, categoryId: t.categoryId, description: t.description, type: t.type.db),
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
        // 目标（游戏层）：名字和进度，让陪聊能接得上「日本游攒得怎么样了」
        for (final p in game.goals.take(3)) '目标：${game.describe(p)}',
        // 信用卡：没还清的账单（陪聊能提醒「招行 25 号到期还剩 3000」，逾期的把违约金 / 利息说清）
        for (final c in cardStatuses())
          if (c.state == CardBillState.due || c.state == CardBillState.overdue)
            '信用卡「${c.account.name}」${c.statementDate.substring(5)} 账单还剩 ${fmtMoney(c.remainingMinor, 'CNY')}，${c.state == CardBillState.overdue ? '已逾期 ${-c.daysToDue} 天，违约金 ${fmtMoney(c.lateFeeMinor, 'CNY')}、利息约 ${fmtMoney(c.interestMinor, 'CNY')}' : '${c.dueDate.substring(5)} 到期，最低还款 ${fmtMoney(c.minPaymentMinor, 'CNY')}'}，可用额度 ${fmtMoney(c.availableMinor, 'CNY')}',
        if (game.enabled && game.metrics?.title != null) '称号「${game.metrics!.title}」${game.metrics!.inDebt ? '（净资产 ${fmtMoney(game.metrics!.netWorthMinor, 'CNY')}，负翁档按欠款分）' : '（等级「${game.metrics!.level!.name}」）'}，可花的 ${fmtMoney(game.metrics!.disposableMinor, 'CNY')}',
      ];
      return lines.join('\n');
    } catch (_) {
      return '';
    }
  }

  /// 一句话 → 解析 → 草稿进收件箱（不落账）。返回解析结果与建立的草稿。
  Future<({InterpretResult result, List<Draft> drafts, QueryResult? query, String? error})> say(String text) async {
    // 下面这些关键词直答（周期账单 / 异常 / 预算）只在句子里没有金额时才拦：「今天花多了，打车花了 80」是在记账，
    // 以前被「花多了」拦下来回了一段异常分析，那 80 块就没记上
    final hasAmount = extractAmounts(text).isNotEmpty;
    // 周期账单 / 预算 的问法不进 Query DSL（它们不是交易聚合），直接答
    if (!hasAmount && RegExp('固定账单|周期账单|订阅|每个月.*(要交|要付|固定)').hasMatch(text) && RegExp('哪些|多少|什么|有没有').hasMatch(text)) {
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
    if (!hasAmount && RegExp('异常|不正常|反常|比平时|花得多|花多了|大额').hasMatch(text)) {
      final now = DateTime.now();
      final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      final a = detectAnomalies(ledger, from: from, to: _today());
      final lines = a.take(5).map((x) => '${x.tx.description ?? categoryName(x.tx.categoryId)} ${Money(x.tx.amountMinor, x.tx.currency)}（${x.tx.occurredAt.localDate.substring(5)}，是${x.basis == 'category' ? '同类' : '平时'}中位数的 ${x.ratio.toStringAsFixed(1)} 倍）').join('；');
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: a.isEmpty ? '这个月没有明显异常的支出。' : '这个月 ${a.length} 笔明显高于平时：$lines');
    }
    if (!hasAmount && RegExp('预算').hasMatch(text) && RegExp('还剩|剩多少|超了|怎么样|多少').hasMatch(text)) {
      final st = ledger.budgets.statuses(today: _today());
      final lines = st.map((s) => '${s.budget.name} 已用 ${Money(s.spentMinor, s.budget.currency)} / ${Money(s.budget.amountMinor, s.budget.currency)}${s.exceeded ? '（已超）' : ''}').join('；');
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: st.isEmpty ? '还没有设置预算（更多 → 预算）' : lines);
    }
    // 目标：「日本游攒了多少」直答；「攒 5000 换手机」→ 目标建议卡（都不出网）
    final goalAnswer = hasAmount ? null : game.answerGoalQuery(text);
    if (goalAnswer != null) {
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: goalAnswer);
    }
    final suggestion = game.suggestFrom(text);
    if (suggestion != null) {
      return (result: const InterpretResult(intent: Intent.chat, interpreter: 'rule'), drafts: const <Draft>[], query: null, error: '想攒 ${fmtMoney(suggestion.amountMinor, 'CNY')} 去「${suggestion.name}」？可以建成一个目标，我帮你盯着进度。');
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
    if (v == null) return (drafts: const <Draft>[], error: settings.offlineMode ? '纯本地模式下不把图片发给模型（更多 → 隐私 可关掉）' : '识别图片需要先配置模型（更多 → 模型与语音）', modelUsed: null);
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
    unawaited(game.onIncomeCommitted(t)); // 工资到账 → 发薪日仪式
    return t;
  }

  List<Transaction> commitGroup(String groupId) {
    final ts = ledger.commitGroup(groupId);
    notifyListeners();
    for (final t in ts) {
      unawaited(game.onIncomeCommitted(t));
    }
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
  /// 起草和确认在同一个事务里：确认失败（校验不过、有退款挡着……）整体回滚，收件箱里不会留下一条垃圾草稿。
  void voidTransaction(String id, String reason) {
    ledger.database.transaction(() {
      final d = ledger.propose([DraftInput(kind: DraftKind.void_, targetTransactionId: id, payload: {'reason': reason})], source: Source.manual, actor: Actor.user).single;
      ledger.commit(d.id);
    });
    notifyListeners();
  }

  /// 修改 = update 草稿 + 立即确认（编辑表单本身就是确认动作）。
  Transaction updateTransaction(String id, Map<String, Object?> patch) {
    final t = ledger.database.transaction(() {
      final d = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: id, payload: patch)], source: Source.manual, actor: Actor.user).single;
      return ledger.commit(d.id);
    });
    notifyListeners();
    return t;
  }

  /// 手动记账 = create 草稿 + 立即确认。
  Transaction addManual(Map<String, Object?> payload) {
    final t = ledger.database.transaction(() {
      final d = ledger.propose([DraftInput(payload: payload)], source: Source.manual, actor: Actor.user).single;
      return ledger.commit(d.id);
    });
    notifyListeners();
    unawaited(game.onIncomeCommitted(t)); // 手动记的工资也触发发薪日仪式
    return t;
  }

  Account addAccount({required String name, required AccountType type, required String currency, int initialBalanceMinor = 0}) {
    final a = ledger.createAccount(name: name, type: type, currency: currency, initialBalanceMinor: initialBalanceMinor);
    notifyListeners();
    return a;
  }

  /// 添加负债：账户 + 每月还款的周期转账 + 还清目标，一次建好（见 ledger_core 的 Debts）。
  DebtSetup addDebt({required String name, required DebtKind kind, required int owedMinor, int monthlyMinor = 0, int day = 1, String? fromAccountId}) {
    final s = ledger.debts.add(name: name, kind: kind, owedMinor: owedMinor, monthlyMinor: monthlyMinor, day: day, fromAccountId: fromAccountId, today: _today());
    if (game.enabled) game.pendingMessages.add((text: replier.template(PersonaEvent.goalCreated, label: s.goal.name), sticker: null, meta: null));
    notifyListeners();
    return s;
  }

  /// 设 / 改一笔负债的每月还款（旧的那条周期转账停掉）。
  Recurring setDebtRepayment(String accountId, {required int monthlyMinor, required int day, required String fromAccountId}) {
    final r = ledger.debts.setRepayment(accountId, monthlyMinor: monthlyMinor, day: day, fromAccountId: fromAccountId, today: _today());
    notifyListeners();
    return r;
  }

  /// 设了条款的信用卡此刻的状态（额度 / 本期账单 / 最低还款 / 逾期费用）；负债页和首页「近期到期」用。
  List<CardStatus> cardStatuses() => ledger.cards.list(today: _today(), currency: 'CNY');

  CardStatus? cardStatus(String accountId) => ledger.cards.status(accountId, today: _today());

  /// 新建一张信用卡（账户 + 条款）。
  Account addCreditCard({required String name, required CardTerms terms, int owedMinor = 0}) {
    final a = ledger.cards.add(name: name, terms: terms, owedMinor: owedMinor);
    notifyListeners();
    return a;
  }

  /// 设 / 改一张信用卡的额度、账单日、还款日、利率这些条款。
  /// 设 / 改条款；[name] 不为空就顺便改名（信用卡、花呗这些建好后也能改名字）。
  void setCardTerms(String accountId, CardTerms terms, {String? name}) {
    ledger.database.transaction(() {
      if (name != null && name.trim().isNotEmpty) ledger.cards.rename(accountId, name);
      ledger.cards.setTerms(accountId, terms);
    });
    notifyListeners();
  }

  /// 还款计划（从今天排到第二个发薪日前）。
  RepaymentPlan repaymentPlan() => RepaymentPlanner(ledger).build(today: _today(), metrics: game.metrics);

  /// 资产体检 + 调优方案。
  Checkup checkup() {
    final m = game.metrics;
    return Checkups(ledger).run(today: _today(), metrics: m, plan: RepaymentPlanner(ledger).build(today: _today(), metrics: m));
  }

  /// 删一笔负债：还款提醒 + 还清目标一起删；账户没还款记录就真删，有就归档（见 Debts.remove）。
  DebtRemoval removeDebt(String accountId) {
    final r = ledger.debts.remove(accountId);
    notifyListeners();
    return r;
  }

  /// 删账户（只允许没有任何交易记录的）。
  void deleteAccount(String id) {
    ledger.deleteAccount(id);
    notifyListeners();
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
      final categoryId = r.type == 'expense' || r.type == 'income' ? rule.guessCategory(text, ctx, kind) : null;
      final accountId = (r.accountHint == null ? null : rule.matchAccount(r.accountHint!, ctx)) ?? ctx.defaultAccountId;
      final refundOf = r.type == 'refund' && r.amountMinor != null
          ? ledger.guessRefundOriginal(amountMinor: r.amountMinor!, currency: r.currency, merchant: r.merchant, at: r.occurredAt?.utc.toLocal())
          : null;
      inputs.add(importedRowToDraft(r, accountId: accountId, categoryId: categoryId, refundOfId: refundOf));
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
  final String? source; // null = 系统通知；'screen' = 支付页识别
  final int? amountMinor; // 当时认出的金额（支付页识别的近期去重用）
  final bool drafted; // 是否真起草了（没被指纹 / 近期去重拦下）
  const RecentNotice({required this.packageName, this.title, required this.text, required this.postedAtMs, required this.templateId, required this.usable, this.source, this.amountMinor, this.drafted = false});

  Map<String, Object?> toJson() => {
        'package': packageName,
        'title': title,
        'text': text,
        'posted_at_ms': postedAtMs,
        'template': templateId,
        'usable': usable,
        if (source != null) 'source': source,
        if (amountMinor != null) 'amount_minor': amountMinor,
        'drafted': drafted,
      };
  factory RecentNotice.fromJson(Map<String, Object?> j) => RecentNotice(
        packageName: j['package'] as String,
        title: j['title'] as String?,
        text: (j['text'] as String?) ?? '',
        postedAtMs: (j['posted_at_ms'] as num?)?.toInt() ?? 0,
        templateId: (j['template'] as String?) ?? 'none',
        usable: j['usable'] == true,
        source: j['source'] as String?,
        amountMinor: (j['amount_minor'] as num?)?.toInt(),
        drafted: j['drafted'] == true,
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
