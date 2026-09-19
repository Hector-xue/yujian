import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import 'src/app_state.dart';
import 'src/db/open_db.dart';
import 'src/dock_host.dart';
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

/// 底栏状态（当前标签 + 盖在首页上的路由动画）：底栏挂在 Navigator 外面，Shell 和覆盖层都看它。
final dockController = DockController();
final _dockObserver = DockObserver(dockController);

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
          // 底栏挂在 Navigator 外面的覆盖层里（见 dock_host.dart），切页时不跟着路由一起被合成，磨砂全程有效
          Widget host(Widget child) => DockHost(controller: dockController, dockBuilder: _buildDock, child: child);
          return MaterialApp(
            title: '余见',
            theme: custom == null ? base : withCustomBackground(base, background),
            debugShowCheckedModeBanner: false,
            showPerformanceOverlay: state.perfOverlay,
            navigatorObservers: [_dockObserver],
            // 背景层截一次图、模糊一次，所有玻璃卡片从它上面取样（见 glass.dart）
            builder: (context, child) => !hasBg
                ? host(child!)
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
                    child: host(child!),
                  ),
            home: const Shell(),
          );
        },
      ),
    );
  }

  /// 底栏内容：首页 · 收件箱 · 对话 · 记录 · 更多（对话放正中间）。
  Widget _buildDock(BuildContext context, int tab, ValueChanged<int> onTab) {
    final inboxCount = AppScope.of(context).inbox.length;
    // tooltip 置空：底栏在 Navigator 外面，没有 Overlay 给它挂提示
    return NavigationBar(
      backgroundColor: Colors.transparent,
      height: dockNavHeight(context),
      selectedIndex: tab,
      onDestinationSelected: onTab,
      destinations: [
        const NavigationDestination(tooltip: '', icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
        NavigationDestination(tooltip: '', 
          icon: Badge(isLabelVisible: inboxCount > 0, label: Text('$inboxCount'), child: const Icon(Icons.inbox_outlined)),
          selectedIcon: Badge(isLabelVisible: inboxCount > 0, label: Text('$inboxCount'), child: const Icon(Icons.inbox)),
          label: '收件箱',
        ),
        const NavigationDestination(tooltip: '', icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: '对话'),
        const NavigationDestination(tooltip: '', icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: '记录'),
        const NavigationDestination(tooltip: '', icon: Icon(Icons.more_horiz), label: '更多'),
      ],
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  @override
  void initState() {
    super.initState();
    // 和以前 Shell 自己持有 _index 一样：新起一个 Shell 从首页开始（帧后再改，别在 build 里 notify 祖先）
    if (dockController.tab != 0 || dockController.cover != null) WidgetsBinding.instance.addPostFrameCallback((_) => dockController.reset());
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
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
      if (target != dockController.tab) WidgetsBinding.instance.addPostFrameCallback((_) => dockController.tab = target);
    } else if (share != null && dockController.tab != chatIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => dockController.tab = chatIndex);
    }
    final pages = [
      const HomePage(),
      const InboxPage(),
      const ChatPage(),
      const TransactionsPage(),
      const MorePage(),
    ];
    // 底栏是 Navigator 外面的悬浮胶囊，页面从它下面滑过；各页列表底部按 MediaQuery.padding.bottom 留位，这里把胶囊的高度加进去。
    // 必须用 Scaffold 体内的 MediaQuery 改（Builder）：外层的还带着键盘 viewInsets，塞回体内会让里面的 Scaffold 再让一次键盘高度，
    // 对话页的输入框就被顶到屏幕上半截。键盘弹出时胶囊被键盘盖着，不再额外留位
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: Builder(builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        return MediaQuery(
          data: keyboard ? mq : mq.copyWith(padding: mq.padding.copyWith(bottom: dockTotalHeight(ctx))),
          child: ListenableBuilder(listenable: dockController, builder: (_, _) => IndexedStack(index: dockController.tab, children: pages)),
        );
      }),
    );
  }
}
