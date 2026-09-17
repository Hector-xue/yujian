import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import 'src/app_state.dart';
import 'src/db/open_db.dart';
import 'src/pages/chat_page.dart';
import 'src/pages/home_page.dart';
import 'src/pages/inbox_page.dart';
import 'src/pages/more_page.dart';
import 'src/pages/transactions_page.dart';
import 'src/notifications/notification_source.dart';
import 'src/settings_store.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openAppDatabase();
  final state = AppState(Ledger(db), settingsStore: PlatformSettingsStore(), notifications: AndroidNotificationSource())..bootstrap();
  await state.loadSettings();
  state.generateRecurring();
  await state.startNotifications();
  await state.startShare();
  runApp(YujianApp(state: state));
  unawaited(state.syncNow()); // 启动后台同步，不挡首屏
  unawaited(state.pushHomeWidget());
}

class YujianApp extends StatelessWidget {
  final AppState state;
  const YujianApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final accent = Color(0xFF000000 | state.persona.accent);
          final spec = themeById(state.settings.themeId);
          return MaterialApp(
            title: '余见',
            theme: spec.build(accent),
            debugShowCheckedModeBanner: false,
            // 全局背景层：玻璃/清新/樱花的渐变放在所有页面下面，页面 Scaffold 透明
            builder: (context, child) => spec.background == null
                ? child!
                : Stack(children: [Positioned.fill(child: spec.background!(context, accent)), ?child]),
            home: const Shell(),
          );
        },
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  var _index = 0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final inboxCount = app.inbox.length;
    // 对话放正中间：首页 · 收件箱 · 对话 · 记录 · 更多
    const chatIndex = 2;
    final share = app.pendingShare;
    if (share != null && share.kind == 'route') {
      // 快捷方式 / 小部件进来的跳转：只切页，不进对话
      app.takeShare();
      final target = switch (share.text) { 'chat' => chatIndex, 'inbox' => 1, 'records' => 3, 'more' => 4, _ => 0 };
      if (target != _index) WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _index = target));
    } else if (share != null && _index != chatIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _index = chatIndex));
    }
    final pages = [
      HomePage(onGoChat: () => setState(() => _index = chatIndex)),
      const InboxPage(),
      const ChatPage(),
      const TransactionsPage(),
      const MorePage(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: Frosted(
          child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
          NavigationDestination(
            icon: Badge(isLabelVisible: inboxCount > 0, label: Text('$inboxCount'), child: const Icon(Icons.inbox_outlined)),
            selectedIcon: Badge(isLabelVisible: inboxCount > 0, label: Text('$inboxCount'), child: const Icon(Icons.inbox)),
            label: '收件箱',
          ),
          const NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: '对话'),
          const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: '记录'),
          const NavigationDestination(icon: Icon(Icons.more_horiz), label: '更多'),
        ],
      )),
    );
  }
}
