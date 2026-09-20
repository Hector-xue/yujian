import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import 'src/app_state.dart';
import 'src/db/open_db.dart';
import 'src/dock_host.dart';
import 'src/glass.dart';
import 'src/pages/chat_page.dart';
import 'src/pages/goals_page.dart';
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
  unawaited(state.startGame()); // 目标 / 任务 / 仪式，不挡首屏
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
      // 用量 / 出网记录平时攒 2 秒再写；这里引擎马上就销毁，得立刻落盘，否则后台那几次模型调用就没人知道
      await state.usage.flush();
      await state.netLog.flush();
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
          // 没有背景层的实色主题：Navigator 底下垫一块主题底色。MaterialApp 切主题时会把 ThemeData 插值 200ms，
          // scaffoldBackgroundColor 从透明（玻璃 / 暖木）渐变到实色的那几帧是半透明的，底下没东西就露出窗口的黑——
          // 「四款主题互相切换会黑闪一下」就是它；玻璃主题切走时背景层又是立刻拆掉的，同样露黑
          Widget host(Widget child) => DockHost(
                controller: dockController,
                dockBuilder: _buildDock,
                child: hasBg ? child : Stack(fit: StackFit.expand, children: [ColoredBox(color: base.colorScheme.surface), child]),
              );
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
      // 快捷方式 / 小部件进来的跳转：只切页，不进对话；「目标」小部件点进来先回首页再推目标页
      app.takeShare();
      final target = switch (share.text) { 'chat' => chatIndex, 'inbox' => 1, 'records' => 3, 'more' => 4, _ => 0 };
      if (target != dockController.tab) WidgetsBinding.instance.addPostFrameCallback((_) => dockController.tab = target);
      if (share.text == 'goals') WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GoalsPage())));
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
    // 留位随键盘连续变化：页面底边 = max(键盘顶, 胶囊顶)。以前是"键盘在就不留位"的开关——键盘收起时输入框先跟着键盘掉到胶囊底下、
    // 到底了再跳回胶囊上面，看起来就是闪一下。
    // 这一层不再套 Scaffold：五个标签页各自是 Scaffold（键盘让位它们自己做）；外面再包一个的话 SnackBar 会在两层 Scaffold 上各画一份，
    // 外层那份贴屏幕底、藏在胶囊下面，磨砂把它的颜色透出来（「大胶囊变色」就是它）。
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final dockTop = dockTotalHeight(context); // viewPadding 不受键盘影响
    final theme = Theme.of(context);
    return Builder(builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      final extra = (dockTop - keyboard).clamp(0.0, dockTop);
      // 标签页里弹的 SnackBar 抬到胶囊上面：悬浮式 SnackBar 只认 insetPadding、不认 MediaQuery.padding，
      // 而 Scaffold 没键盘时已经替它让过底部安全区（有键盘时让的是键盘），这里别再让一次
      final safe = keyboard > 0 ? 0.0 : mq.viewPadding.bottom;
      final snackInset = (extra + 10 - safe).clamp(10.0, double.infinity);
      return MediaQuery(
        data: mq.copyWith(padding: mq.padding.copyWith(bottom: extra > mq.padding.bottom ? extra : mq.padding.bottom)),
        // 子页盖上来时胶囊已滑走，子页不在这层里，不受影响
        child: Theme(
          data: theme.copyWith(snackBarTheme: theme.snackBarTheme.copyWith(insetPadding: EdgeInsets.fromLTRB(15, 5, 15, snackInset))),
          child: ListenableBuilder(listenable: dockController, builder: (_, _) => IndexedStack(index: dockController.tab, children: pages)),
        ),
      );
    });
  }
}
