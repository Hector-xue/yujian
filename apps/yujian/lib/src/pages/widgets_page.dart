import 'package:flutter/material.dart';

import '../app_state.dart';
import '../platform/home_widget_bridge.dart';
import '../theme.dart';

/// 桌面小部件：列出五种小部件（预览图 + 尺寸 + 内容），支持的桌面上一键「添加到桌面」，不支持的给手动加法。
class WidgetsPage extends StatefulWidget {
  const WidgetsPage({super.key});
  @override
  State<WidgetsPage> createState() => _WidgetsPageState();
}

class _WidgetKind {
  final String kind; // 原生侧 WidgetBridge 认的种类名
  final String name;
  final int cols;
  final int rows;
  final String desc;
  const _WidgetKind(this.kind, this.name, this.cols, this.rows, this.desc);
  String get cells => '$cols×$rows';
}

const _kinds = [
  _WidgetKind('summary', '本月', 4, 2, '本月支出、收入、余额 + 财富称号，一键记一笔'),
  _WidgetKind('calendar', '日历', 4, 4, '月历：每天的支出 / 收入 + 本月收支 + 称号 + 记一笔'),
  _WidgetKind('large', '今日', 2, 2, '今日支出 + 称号 + 本月 + 记一笔'),
  _WidgetKind('compact', '余额', 2, 1, '余额 + 称号 + 记一笔'),
  _WidgetKind('mini', '记一笔', 1, 1, '一个记一笔按钮，点开直接进对话'),
];

/// 预览按桌面格子等比画：一格 ≈ 66dp，4 格宽的和 1 格宽的一眼能看出大小差别，也不会把 140px 的小图拉糊。
const _cell = 66.0;

class _WidgetsPageState extends State<WidgetsPage> {
  bool? _pinSupported; // null = 还没问到原生
  var _probed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_probed) {
      _probed = true;
      _probe();
    }
  }

  Future<void> _probe() async {
    final bridge = AppScope.of(context).homeWidget;
    final ok = bridge == null ? false : await bridge.pinSupported();
    if (mounted) setState(() => _pinSupported = ok);
  }

  Future<void> _pin(_WidgetKind k) async {
    final app = AppScope.of(context);
    final bridge = app.homeWidget;
    final messenger = ScaffoldMessenger.of(context);
    final ok = bridge == null ? false : await bridge.pin(k.kind);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('这个桌面不支持从 App 内添加，请长按桌面空白处 → 小部件 → 余见')));
      return;
    }
    // 请求已发给桌面：正常会弹「添加到主屏幕」确认框。小米 / HyperOS 会静默吞掉，得先在应用信息页允许「桌面快捷方式」
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: const Text('已请求桌面添加。没弹确认框的话：小米 / HyperOS 要先在应用信息页 → 权限管理 → 允许「桌面快捷方式」，或长按桌面空白处 → 小部件 → 余见手动加'),
      action: SnackBarAction(label: '应用信息', onPressed: () => app.notifications.openAppInfo()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final android = HomeWidgetBridge.supported;
    return Scaffold(
      appBar: AppBar(title: const Text('桌面小部件')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text(
            !android
                ? '小部件只有 Android 有。'
                : _pinSupported == false
                    ? '这个桌面不支持从 App 内添加：长按桌面空白处 → 小部件（或「添加工具」）→ 找到「余见」，拖到桌面。'
                    : '点「添加到桌面」，系统会弹确认框；也可以长按桌面空白处 → 小部件 → 余见。数字随账本自动刷新。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          for (final k in _kinds) ...[
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text('余见 · ${k.name}', style: theme.textTheme.titleSmall),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
                        child: Text(k.cells, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                      ),
                      const Spacer(),
                      if (android && _pinSupported != false)
                        FilledButton.tonal(onPressed: _pinSupported == null ? null : () => _pin(k), child: const Text('添加到桌面')),
                    ]),
                    const SizedBox(height: 4),
                    Text(k.desc, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: _cell * k.cols,
                        height: _cell * k.rows,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(y.radius * 0.5),
                          child: Image.asset('assets/widgets/${k.kind}.png', fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}
