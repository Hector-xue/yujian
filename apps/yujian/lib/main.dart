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
}

class YujianApp extends StatelessWidget {
  final AppState state;
  const YujianApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: '余见',
        theme: buildTheme(),
        debugShowCheckedModeBanner: false,
        home: const Shell(),
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
    if (app.pendingShare != null && _index != 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _index = 1));
    }
    final pages = [
      HomePage(onGoChat: () => setState(() => _index = 1)),
      const ChatPage(),
      const InboxPage(),
      const TransactionsPage(),
      const MorePage(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
          const NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: '对话'),
          NavigationDestination(
            icon: Badge(isLabelVisible: inboxCount > 0, label: Text('$inboxCount'), child: const Icon(Icons.inbox_outlined)),
            selectedIcon: Badge(isLabelVisible: inboxCount > 0, label: Text('$inboxCount'), child: const Icon(Icons.inbox)),
            label: '收件箱',
          ),
          const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: '记录'),
          const NavigationDestination(icon: Icon(Icons.more_horiz), label: '更多'),
        ],
      ),
    );
  }
}
