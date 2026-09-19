import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import 'src/app_state.dart';
import 'src/db/open_db.dart';
import 'src/glass.dart';
import 'src/pages/chat_page.dart';
import 'src/pages/home_page.dart';
import 'src/pages/inbox_page.dart';
import 'src/pages/more_page.dart';
import 'src/pages/transactions_page.dart';
import 'src/platform/avatar_files_native.dart' if (dart.library.js_interop) 'src/platform/avatar_files_web.dart';
import 'src/platform/home_widget_bridge.dart';
import 'src/notifications/notification_source.dart';
import 'src/notifications/screenshot_source.dart';
import 'src/settings_store.dart';
import 'src/theme.dart';
import 'src/update/update_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openAppDatabase();
  final state = AppState(Ledger(db), settingsStore: PlatformSettingsStore(), notifications: AndroidNotificationSource(), screenshots: AndroidScreenshotSource(), homeWidget: HomeWidgetBridge.ifSupported())..bootstrap();
  await state.loadSettings();
  await GlassShaders.load(); // 玻璃着色器：一次编译，全 App 共用
  state.generateRecurring();
  await state.startNotifications();
  await state.startShare();
  runApp(YujianApp(state: state));
  unawaited(state.syncNow()); // 启动后台同步，不挡首屏
  unawaited(state.startScreenshots()); // 截图队列要调视觉模型，不挡首屏
  unawaited(state.pushHomeWidget());
  unawaited(state.checkUpdate());
}

/// 无头引擎入口：App 没开着、但进程被通知监听 / 无障碍留着时，原生 ScreenshotBridge 起这个入口把截图队列处理掉。
/// 只做一件事——吃队列、按模式入账、刷小部件——然后告诉原生销毁引擎。不 runApp。
@pragma('vm:entry-point')
Future<void> screenshotBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  final shots = AndroidScreenshotSource();
  try {
    final db = await openAppDatabase();
    final state = AppState(Ledger(db), settingsStore: PlatformSettingsStore(), notifications: AndroidNotificationSource(), screenshots: shots, homeWidget: HomeWidgetBridge.ifSupported());
    await state.loadSettings();
    if (state.settings.screenshotWanted) {
      await state.ingestScreenshots(await shots.drain());
      await state.pushHomeWidget();
    }
  } catch (e) {
    await shots.log({'what': 'background_error', 'err': '$e'});
  } finally {
    await shots.backgroundDone();
  }
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
          final base = spec.build(accent);
          final bgPath = state.settings.backgroundImage ?? '';
          final bgOpacity = state.settings.backgroundOpacity.clamp(0.0, 1.0);
          final bgWidth = View.of(context).physicalSize.width.round(); // 按屏幕物理宽度解码，别把几千像素的原图整张塞进显存
          final custom = bgPath.isEmpty ? null : backgroundImage(bgPath, cacheWidth: bgWidth, opacity: bgOpacity); // 文件没了就当没设
          // 全局背景层：主题自己的渐变（或纯色）在最下面，用户的背景图按可见度叠在上面，页面 Scaffold 透明
          Widget background(BuildContext context) => Stack(fit: StackFit.expand, children: [
                spec.background?.call(context, accent) ?? ColoredBox(color: base.colorScheme.surface),
                ?custom,
              ]);
          final hasBg = spec.background != null || custom != null;
          final y = base.extension<YujianColors>()!;
          return MaterialApp(
            title: '余见',
            theme: custom == null ? base : withCustomBackground(base, background),
            debugShowCheckedModeBanner: false,
            showPerformanceOverlay: state.perfOverlay,
            // 背景层截一次图、模糊一次，所有玻璃卡片从它上面取样（见 glass.dart）
            builder: (context, child) => !hasBg
                ? child!
                : GlassBackdrop(
                    signature: (spec.id, accent.toARGB32(), bgPath, bgOpacity, bgWidth),
                    sigma: y.blur,
                    warmUp: custom == null
                        ? null
                        : (ctx) async {
                            final p = backgroundImageProvider(bgPath, cacheWidth: bgWidth);
                            if (p != null) await precacheImage(p, ctx);
                          },
                    background: background(context),
                    child: child!,
                  ),
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
    final upd = app.availableUpdate;
    if (upd != null && !app.updatePrompted) {
      app.updatePrompted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => showUpdateSheet(context, upd, onSkip: () => app.skipUpdate(upd.version)));
    }
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
      const HomePage(),
      const InboxPage(),
      const ChatPage(),
      const TransactionsPage(),
      const MorePage(),
    ];
    return Scaffold(
      // 页面从底栏下面滑过（底栏是悬浮胶囊，不再是贴边的一整条）；各页列表底部按 MediaQuery.padding.bottom 留位
      extendBody: true,
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: Dock(
          child: NavigationBar(
        backgroundColor: Colors.transparent,
        // 高度跟着系统字号走：内容 = 指示胶囊 32 + 标签上距 4 + 标签一行(字号 12，NavigationBar 内部把标签缩放封顶 1.3)，
        // 再留上下各 ~6。写死 60 在大字号手机上内容会顶出底栏（选中胶囊贴着/超出上边）
        height: 50 + MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3).scale(18),
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
