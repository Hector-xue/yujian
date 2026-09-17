import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../widgets/fmt.dart';

/// 自动记账（§11）：通知监听开关、三种模式、自动入账日志、模板试验。
class AutomationPage extends StatefulWidget {
  const AutomationPage({super.key});
  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> with WidgetsBindingObserver {
  bool? systemEnabled;
  bool? screenEnabled;
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
    final n = AppScope.of(context).notifications;
    final v = await n.isEnabled();
    final sc = await n.isScreenEnabled();
    if (mounted) {
      setState(() {
        systemEnabled = v;
        screenEnabled = sc;
      });
    }
  }

  Future<void> _addTemplate(BuildContext context) async {
    final app = AppScope.of(context);
    final id = TextEditingController();
    final pkg = TextEditingController(text: 'com.tencent.mm');
    final re = TextEditingController(text: r'已支付[¥￥]?(?<amount>\d+(?:\.\d{1,2})?)');
    final hint = TextEditingController();
    var direction = 'expense';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: const Text('新模板'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: id, decoration: const InputDecoration(labelText: '名字', hintText: 'my_bank')),
                const SizedBox(height: 12),
                TextField(controller: pkg, decoration: const InputDecoration(labelText: '包名（留空=任意）')),
                const SizedBox(height: 12),
                TextField(controller: re, decoration: const InputDecoration(labelText: '正文正则', helperText: '必须含 (?<amount>数字) 分组；可选 (?<merchant>…)'), maxLines: 2),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: direction,
                  decoration: const InputDecoration(labelText: '方向'),
                  items: const [
                    DropdownMenuItem(value: 'expense', child: Text('支出')),
                    DropdownMenuItem(value: 'income', child: Text('收入')),
                    DropdownMenuItem(value: 'transfer', child: Text('转账')),
                    DropdownMenuItem(value: '', child: Text('按关键词判'))
                  ],
                  onChanged: (v) => setState(() => direction = v ?? ''),
                ),
                const SizedBox(height: 12),
                TextField(controller: hint, decoration: const InputDecoration(labelText: '账户线索（可选）', hintText: '招行')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      RegExp(re.text); // 先验证正则
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('正则不合法：${e.message}')));
      return;
    }
    if (id.text.trim().isEmpty || !re.text.contains('(?<amount>')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('要有名字，正则要有 (?<amount>…) 分组')));
      return;
    }
    final t = <String, Object?>{
      'id': id.text.trim(),
      'packages': pkg.text.trim().isEmpty ? <String>[] : [pkg.text.trim()],
      'text_re': re.text,
      if (direction.isNotEmpty) 'direction': direction,
      if (hint.text.trim().isNotEmpty) 'account_hint': hint.text.trim(),
      'confidence': 0.9,
    };
    await app.saveSettings(app.settings.copyWith(userTemplates: [...app.settings.userTemplates.where((x) => x['id'] != t['id']), t]));
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
          Text('两条路，建议都开：微信 / 支付宝付款时 App 在前台，系统不弹通知，只有「支付页识别」能抓到；银行、购物平台的到账 / 支付通知则由「通知自动记账」读。都只在本机处理，不读短信，关掉随时生效。', style: theme.textTheme.bodySmall),
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
          Row(
            children: [
              Expanded(child: Text('自定义模板', style: theme.textTheme.titleMedium)),
              TextButton.icon(onPressed: () => _addTemplate(context), icon: const Icon(Icons.add, size: 18), label: const Text('新建')),
            ],
          ),
          Text('内置模板认不出的通知，自己写一条：包名 + 正则（金额用 (?<amount>…) 分组）。用户模板优先于内置。', style: theme.textTheme.bodySmall),
          for (final t in s.userTemplates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${t['id']} · ${(t['packages'] as List?)?.join(',') ?? '任意包'}'),
              subtitle: Text('${t['text_re']} → ${t['direction'] ?? '按关键词'}${t['account_hint'] != null ? ' · ${t['account_hint']}' : ''}', style: theme.textTheme.bodySmall),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => app.saveSettings(s.copyWith(userTemplates: [
                  for (final x in s.userTemplates)
                    if (x['id'] != t['id']) x
                ])),
              ),
            ),
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
