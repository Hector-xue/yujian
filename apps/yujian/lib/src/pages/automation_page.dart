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
    final v = await AppScope.of(context).notifications.isEnabled();
    if (mounted) setState(() => systemEnabled = v);
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
          Text('读取支付类通知（微信、支付宝、银行 App）生成记录。只读通知，不读短信；关掉随时生效。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
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
