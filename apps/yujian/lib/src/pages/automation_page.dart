import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../widgets/fmt.dart';
import '../widgets/learn_template_sheet.dart';

/// 自动记账（§11）：通知监听开关、三种模式、自动入账日志、模板试验。
class AutomationPage extends StatefulWidget {
  const AutomationPage({super.key});
  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> with WidgetsBindingObserver {
  bool? systemEnabled;
  bool? screenEnabled;
  Map<String, Object?> screenDiag = const {};
  ({bool permitted, bool partial})? shotStatus;
  Map<String, Object?> shotDiag = const {};
  final testText = TextEditingController();
  String? testResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // 从系统设置回来
  }

  Future<void> _refresh() async {
    final app = AppScope.of(context);
    final n = app.notifications;
    final v = await n.isEnabled();
    final sc = await n.isScreenEnabled();
    final diag = await n.screenDiagnostics();
    final shots = app.screenshots;
    final ss = await shots.status();
    final sd = await shots.diagnostics();
    if (mounted) {
      setState(() {
        systemEnabled = v;
        screenEnabled = sc;
        screenDiag = diag;
        shotStatus = ss;
        shotDiag = sd;
      });
    }
  }

  /// 截图自动记账的处理记录：每张图记了 / 进收件箱 / 忽略 / 出错，一眼看出模型怎么判的。
  Widget _screenshotLog(BuildContext context, AppState app) {
    final theme = Theme.of(context);
    final log = app.screenshotLog;
    final observing = shotDiag['observing'] == true;
    final pending = (shotDiag['pending'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text('截图处理记录', style: theme.textTheme.titleSmall)),
              TextButton(onPressed: _refresh, child: const Text('刷新')),
            ]),
            Text('${observing ? '正在盯着相册' : '观察者没在（App 进后台被杀后，下次打开会补扫最近 24 小时）'}${pending > 0 ? ' · $pending 张待处理' : ''}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            if (log.isEmpty)
              Text('还没处理过截图。截一张支付页 / 订单页试试', style: theme.textTheme.bodySmall)
            else
              for (final o in log.take(8))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                      switch (o.outcome) { 'recorded' => Icons.check_circle_outline, 'inbox' => Icons.inbox_outlined, 'error' => Icons.error_outline, _ => Icons.remove_circle_outline },
                      size: 16,
                      color: switch (o.outcome) { 'recorded' || 'inbox' => theme.colorScheme.primary, 'error' => theme.colorScheme.error, _ => theme.textTheme.bodySmall?.color },
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${fmtRelativeMs(o.atMs)} · ${o.detail}${o.modelUsed != null ? ' · ${o.modelUsed}' : ''}', style: theme.textTheme.bodySmall)),
                  ]),
                ),
          ],
        ),
      ),
    );
  }

  /// 支付页识别的诊断面板：把原生侧每一步的记录摆出来，没识别到时能看出卡在哪一环。
  Widget _screenDiagnostics(BuildContext context, AppState app) {
    final theme = Theme.of(context);
    final d = screenDiag;
    final connectedAt = (d['connected_at'] as num?)?.toInt() ?? 0;
    final lastEventAt = (d['last_event_at'] as num?)?.toInt() ?? 0;
    final lastPkg = d['last_event_pkg'] as String? ?? '';
    final wanted = d['wanted'] == true;
    final log = ((d['log'] as List?) ?? const []).cast<Map>().reversed.toList();
    String when(int ms) => ms <= 0 ? '—' : fmtRelativeMs(ms);
    final lines = <String>[
      '系统无障碍：${screenEnabled == true ? '已开' : '未开'}',
      '余见开关（原生侧）：${wanted ? '开' : '关'}',
      '服务连接：${connectedAt > 0 ? '已连接（${when(connectedAt)}）' : '未连接'}',
      '最近事件：${lastEventAt > 0 ? '${when(lastEventAt)} · ${_appName(lastPkg)}' : '还没收到过'}',
    ];
    final verdict = screenEnabled != true
        ? '系统里还没打开，服务不会启动'
        : !wanted
            ? '原生侧开关是关的，重新拨一次上面的开关'
            : connectedAt <= 0
                ? '系统说已开但服务没连上：小米 / HyperOS 常在 App 更新或重启后把无障碍服务掐掉，去系统无障碍页关一下再开；应用信息页里把「自启动」打开'
                : lastEventAt <= 0
                    ? '服务在，但还没收到过支付 / 购物 App 的事件：去微信付一笔看这里会不会变'
                    : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text('识别诊断', style: theme.textTheme.titleSmall)),
          TextButton(onPressed: _refresh, child: const Text('刷新')),
          TextButton(
            onPressed: () async {
              await app.notifications.clearScreenLog();
              await _refresh();
            },
            child: const Text('清空'),
          ),
        ]),
        for (final l in lines) Text(l, style: theme.textTheme.bodySmall),
        if (verdict != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(verdict, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error))),
        if (log.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final e in log.take(30)) Text(_logLine(e), style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ],
    );
  }

  static const _appNames = {
    'com.tencent.mm': '微信',
    'com.eg.android.AlipayGphone': '支付宝',
    'com.unionpay': '云闪付',
    'com.taobao.taobao': '淘宝',
    'com.tmall.wireless': '天猫',
    'com.jingdong.app.mall': '京东',
    'com.xunmeng.pinduoduo': '拼多多',
    'com.sankuai.meituan': '美团',
    'com.sankuai.meituan.takeoutnew': '美团外卖',
    'me.ele': '饿了么',
    'com.ss.android.ugc.aweme': '抖音',
    'com.xingin.xhs': '小红书',
    'com.sdu.didi.psnger': '滴滴',
    'com.MobileTicket': '12306',
    'ctrip.android.view': '携程',
    'com.dianping.v1': '大众点评',
  };
  static String _appName(String pkg) => _appNames[pkg] ?? pkg;

  static String _logLine(Map e) {
    final t = (e['t'] as num?)?.toInt() ?? 0;
    final time = t > 0 ? DateTime.fromMillisecondsSinceEpoch(t).toIso8601String().substring(5, 16).replaceFirst('T', ' ') : '';
    final pkg = _appName(e['pkg'] as String? ?? '');
    final count = (e['count'] as num?)?.toInt() ?? 1;
    final n = (e['n'] as num?)?.toInt();
    final what = switch (e['what']) {
      'connected' => '服务已连接',
      'unbound' => '服务被系统解绑',
      'not_wanted' => '$pkg 有事件，但余见开关是关的',
      'no_root' => '$pkg 有事件，但读不到窗口内容',
      'no_success_text' => '$pkg 页面里没有「支付成功」字样（${n ?? 0} 段文字）',
      'no_amount' => '$pkg 有「支付成功」但没读到金额：${((e['sample'] as List?) ?? const []).join(' | ')}',
      'dup' => '$pkg ¥${e['amount']} 两分钟内重复，跳过',
      'enqueued' => '$pkg ¥${e['amount']} ${e['merchant'] ?? ''} → 已送进收件箱',
      _ => '${e['what']}',
    };
    return '$time  $what${count > 1 ? ' ×$count' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final s = app.settings;
    final supported = app.notifications.supported;
    final autoLog = app.ledger.listTransactions(limit: 200).where((t) => t.source == Source.notification).take(20).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('自动记账')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('三条路，按需开：微信 / 支付宝付款时 App 在前台，系统不弹通知，「支付页识别」抓支付成功那一刻；银行、购物平台的到账 / 支付通知由「通知自动记账」读；没有「支付成功」字样的消费（订单页、账单、小票）截个图，「截图自动记账」让视觉模型看一眼。前两条只在本机处理；截图会发给你配置的模型。关掉随时生效。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('支付页识别'),
            subtitle: Text(
              !supported
                  ? '仅 Android 支持'
                  : screenEnabled == false
                      ? '在微信、支付宝、淘宝、京东、美团等出现「支付成功」页面时读金额和商户。需要在系统「无障碍」里打开「余见 · 支付页识别」'
                      : '系统已授权。只看支付 / 购物 App，只在支付成功那一刻读一次',
              style: theme.textTheme.bodySmall,
            ),
            value: s.screenWanted,
            onChanged: !supported
                ? null
                : (v) async {
                    await app.saveSettings(s.copyWith(screenWanted: v));
                    await app.notifications.setScreenWanted(v);
                    if (v && screenEnabled != true) await app.notifications.openScreenSettings();
                    if (v) await app.startNotifications();
                    _refresh();
                  },
          ),
          if (supported && s.screenWanted && screenEnabled == false) ...[
            Text('系统设置 → 无障碍 → 已下载的应用（或「更多已下载的服务」）→ 余见 · 支付页识别 → 打开。小米 / HyperOS 点不动或提示「受限制的设置」的话，先到应用信息页右上角 ⋮ →「允许受限设置」，再回来开。', style: theme.textTheme.bodySmall),
            Row(children: [
              TextButton.icon(onPressed: () => app.notifications.openScreenSettings(), icon: const Icon(Icons.accessibility_new, size: 18), label: const Text('去无障碍设置')),
              TextButton.icon(onPressed: () => app.notifications.openAppInfo(), icon: const Icon(Icons.info_outline, size: 18), label: const Text('应用信息页')),
            ]),
          ],
          if (supported && s.screenWanted) Padding(padding: const EdgeInsets.only(top: 4), child: _screenDiagnostics(context, app)),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('通知自动记账'),
            subtitle: Text(
              !supported
                  ? '仅 Android 支持'
                  : systemEnabled == false
                      ? '还没在系统里授权，打开后会跳到系统设置'
                      : '系统已授权',
              style: theme.textTheme.bodySmall,
            ),
            value: s.notificationsWanted,
            onChanged: !supported
                ? null
                : (v) async {
                    await app.saveSettings(s.copyWith(notificationsWanted: v));
                    if (v && systemEnabled != true) await app.notifications.openSettings();
                    if (v) await app.startNotifications();
                    _refresh();
                  },
          ),
          if (supported && systemEnabled == false) ...[
            const SizedBox(height: 4),
            Text('系统弹「已拒绝此应用获取敏感权限 / 未知来源应用」？这是小米、HyperOS 等对非商店安装 App 的限制：先到应用信息页，右上角 ⋮ →「允许受限设置」，再回来打开。', style: theme.textTheme.bodySmall),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => app.notifications.openAppInfo(), icon: const Icon(Icons.info_outline, size: 18), label: const Text('打开应用信息页')),
            ),
          ],
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('截图自动记账'),
            subtitle: Text(
              !supported
                  ? '仅 Android 支持'
                  : !app.hasModel
                      ? '要先配置一个能看图的模型（更多 → 模型与人格）'
                      : shotStatus?.partial == true
                          ? '相册权限只给了「部分照片」，看不到新截图：到应用信息页改成「允许全部」'
                          : s.screenshotWanted
                              ? '相册里新出现的截图会发给模型判断：是支付页 / 订单 / 账单 / 小票就按下面的模式记账，不是就忽略'
                              : '截一张支付页、订单页或小票，不用打开余见也能记。需要相册读取权限；每张新截图都会发给你配置的模型',
              style: theme.textTheme.bodySmall,
            ),
            value: s.screenshotWanted,
            onChanged: !supported || !app.hasModel
                ? null
                : (v) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final ok = await app.setScreenshotWanted(v);
                    if (v && !ok) messenger.showSnackBar(const SnackBar(content: Text('没拿到相册权限，截图自动记账没打开')));
                    _refresh();
                  },
          ),
          if (supported && s.screenshotWanted && shotStatus?.partial == true)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => app.notifications.openAppInfo(), icon: const Icon(Icons.info_outline, size: 18), label: const Text('去应用信息页改权限')),
            ),
          if (supported && s.screenshotWanted) ...[
            Text('后台也能记的前提是余见进程还活着：开了「通知自动记账」或「支付页识别」系统会替它留着；国产系统还得在设置里允许余见自启动 / 后台运行。进程被杀期间截的图，下次打开余见时补扫最近 24 小时。', style: theme.textTheme.bodySmall),
            Padding(padding: const EdgeInsets.only(top: 4), child: _screenshotLog(context, app)),
          ],
          const SizedBox(height: 16),
          Text('模式', style: theme.textTheme.titleMedium),
          RadioGroup<AutomationMode>(
            groupValue: s.automationMode,
            onChanged: (v) => app.saveSettings(s.copyWith(automationMode: v)),
            child: Column(
              children: const [
                RadioListTile(value: AutomationMode.confirm, contentPadding: EdgeInsets.zero, title: Text('确认模式'), subtitle: Text('每一笔都进收件箱，由你确认')),
                RadioListTile(value: AutomationMode.smart, contentPadding: EdgeInsets.zero, title: Text('智能模式'), subtitle: Text('金额、商户、账户都明确且不重复的自动入账，其余进收件箱')),
                RadioListTile(value: AutomationMode.silent, contentPadding: EdgeInsets.zero, title: Text('静默模式'), subtitle: Text('能入账的都自动入账，只有缺字段或疑似重复的才问你')),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('自动入账记录', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          if (autoLog.isEmpty) Text('还没有由通知生成的记录', style: theme.textTheme.bodySmall),
          for (final t in autoLog)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.description ?? app.categoryName(t.categoryId)),
              subtitle: Text('${t.occurredAt.localDate} · ${app.categoryName(t.categoryId)} · ${app.accountName(t.accountId)}', style: theme.textTheme.bodySmall),
              trailing: Text(fmtSigned(t), style: theme.textTheme.titleMedium),
              onLongPress: () {
                app.voidTransaction(t.id, '撤销自动记账');
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已撤销')));
              },
            ),
          if (autoLog.isNotEmpty) Text('长按一条可撤销', style: theme.textTheme.bodySmall),
          const SizedBox(height: 24),
          Text('教它认一种通知', style: theme.textTheme.titleMedium),
          Text('有些 App 的通知内置规则认不出（银行、小众平台）：拿一条真实通知当例子，点一下金额、选个方向就行，不用懂包名和正则。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                final n = await pickRecentNotice(context);
                if (n == null || !context.mounted) return;
                await showLearnTemplateSheet(context, from: n);
              },
              icon: const Icon(Icons.notifications_none, size: 18),
              label: const Text('从最近的通知里选'),
            ),
            OutlinedButton.icon(onPressed: () => showLearnTemplateSheet(context), icon: const Icon(Icons.content_paste, size: 18), label: const Text('粘贴通知文字')),
          ]),
          for (final t in s.userTemplates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${t['id']}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                t['sample'] is String && (t['sample'] as String).isNotEmpty
                    ? '例：${t['sample']}'
                    : '${t['text_re']} → ${t['direction'] ?? '按关键词'}${t['account_hint'] != null ? ' · ${t['account_hint']}' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              onTap: () => showLearnTemplateSheet(context, edit: t),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => app.saveSettings(s.copyWith(userTemplates: [
                  for (final x in s.userTemplates)
                    if (x['id'] != t['id']) x
                ])),
              ),
            ),
          if (s.userTemplates.isNotEmpty) Text('点一条可以改', style: theme.textTheme.bodySmall),
          const SizedBox(height: 24),
          Text('试试模板', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('把一条支付通知的文字粘进来，看余见能不能读懂。读不懂的可以在 GitHub 提 Issue，会做成模板。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(controller: testText, maxLines: 3, decoration: const InputDecoration(hintText: '已支付¥19.90，商户：瑞幸咖啡')),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: () {
                  final x = app.tryTemplate('com.tencent.mm', '微信支付', testText.text);
                  setState(() => testResult = x.ignored
                      ? '判定为无关通知（营销/验证码）'
                      : x.usable
                          ? '${x.direction == 'income' ? '收入' : x.direction == 'transfer' ? '转账' : '支出'} ${fmtMoney(x.amountMinor!, x.currency)}${x.merchant != null ? ' · ${x.merchant}' : ''} · 模板 ${x.templateId} · 置信 ${(x.confidence * 100).round()}%'
                          : '没抽到金额或方向，这种会进收件箱附原文');
                },
                child: const Text('解析'),
              ),
              const SizedBox(width: 12),
              if (testResult != null) Expanded(child: Text(testResult!, style: theme.textTheme.bodySmall)),
            ],
          ),
        ],
      ),
    );
  }
}
