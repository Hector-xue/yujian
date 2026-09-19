import 'package:flutter/material.dart';

import 'theme.dart';

/// 底栏挂在 Navigator 外面（MaterialApp.builder 的覆盖层），不再是 Shell 的 bottomNavigationBar。
///
/// 为什么：切页时整条路由被套进淡入淡出 / 位移层，底栏跟着一起被合成——Impeller 在那层里不给 BackdropFilter 做真正的回读，
/// 切换的那几百毫秒胶囊后面的字是清晰的，看起来就是闪一下。挂在外面它永远在静止的合成层里，磨砂全程有效；
/// 推入 / 弹出子页时它按那条路由自己的动画滑下 / 滑回，和页面同步，不会突兀。
class DockController extends ChangeNotifier {
  int _tab = 0;
  int get tab => _tab;
  set tab(int v) {
    if (v == _tab) return;
    _tab = v;
    notifyListeners();
  }

  void reset() {
    _tab = 0;
    _cover = null;
    notifyListeners();
  }

  /// 当前盖在首页之上的那条路由的动画（0 = 首页可见，1 = 子页完全盖住）；null = 没有子页。
  Animation<double>? _cover;
  Animation<double>? get cover => _cover;
  void _setCover(Animation<double>? a) {
    if (identical(a, _cover)) return;
    _cover = a;
    notifyListeners();
  }
}

/// 跟着 Navigator 记录「首页上面有没有东西」，把那条路由的动画交给底栏。
class DockObserver extends NavigatorObserver {
  final DockController controller;
  DockObserver(this.controller);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return; // 首页本身
    controller._setCover(route.animation);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    if (previousRoute.isFirst) {
      // 弹回首页：跟着正在退出的这条路由反向动画（1 → 0）滑回来，走完就不再引用它（它的控制器随后会销毁）
      final a = route.animation;
      controller._setCover(a);
      if (a == null) return;
      void done(AnimationStatus s) {
        if (s != AnimationStatus.dismissed) return;
        a.removeStatusListener(done);
        if (identical(controller._cover, a)) controller._setCover(null);
      }
      a.addStatusListener(done);
    } else {
      controller._setCover(previousRoute.animation);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null || previousRoute.isFirst) controller._setCover(null);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null && !newRoute.isFirst) controller._setCover(newRoute.animation);
  }
}

/// 底栏胶囊里 NavigationBar 的高度：内容 = 指示胶囊 32 + 标签上距 4 + 标签一行（字号 12，封顶 1.3 倍），再留上下各 ~6。
/// 写死 60 在大字号手机上内容会顶出底栏。
double dockNavHeight(BuildContext context) => 50 + MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3).scale(18);

/// 底栏从屏幕底边算起占的总高度（胶囊 + 下边距）。首页各页列表底部按它留位。
double dockTotalHeight(BuildContext context) {
  final inset = MediaQuery.paddingOf(context).bottom;
  return dockNavHeight(context) + (inset > 0 ? inset + 2 : 10);
}

/// 覆盖层：Navigator 在下，底栏钉在底边；子页盖上来时按它的动画滑出屏幕。
class DockHost extends StatelessWidget {
  final DockController controller;
  final Widget child;
  final Widget Function(BuildContext context, int tab, ValueChanged<int> onTab) dockBuilder;
  const DockHost({super.key, required this.controller, required this.child, required this.dockBuilder});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final cover = controller.cover;
              final dock = Dock(child: dockBuilder(context, controller.tab, (i) => controller.tab = i));
              if (cover == null) return dock;
              final hide = dockTotalHeight(context) + 24;
              return AnimatedBuilder(
                animation: cover,
                builder: (context, child) {
                  final t = Curves.easeInOut.transform(cover.value.clamp(0.0, 1.0));
                  return IgnorePointer(
                    ignoring: t > 0.5,
                    child: Transform.translate(offset: Offset(0, hide * t), child: child),
                  );
                },
                child: dock,
              );
            },
          ),
        ),
      ],
    );
  }
}
