import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 玻璃着色器（shaders/glass.frag）：一份 GLSL 两种用法。
/// - 真悬浮层（底栏）：当 BackdropFilter 用，底下的内容滚过时实时折射（只在 Impeller 上，Skia 退回模糊）。
/// - 内容卡片：对预模糊的全局背景按屏幕位置取样（[GlassBackdrop]），背景静止所以每帧零回读。
///
/// 为什么不是每张卡都 BackdropFilter：每个 BackdropFilter = 打断渲染通道 + 回读底下画面 + 两遍高斯，一屏七八个手机 GPU 顶不住；
/// 内容卡片下面只有静止背景，预模糊一张图取样，视觉上一样。
class GlassShaders {
  static ui.FragmentProgram? _program;

  static Future<void> load() async {
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/glass.frag');
    } catch (e) {
      debugPrint('glass shader unavailable: $e');
    }
  }

  static bool get available => _program != null;

  /// 真 BackdropFilter 路径（ImageFilter.shader）只有 Impeller 有。
  static bool get backdropSupported => _program != null && ui.ImageFilter.isShaderFilterSupported;

  static ui.FragmentShader? create() => _program?.fragmentShader();
}

/// 一片玻璃的材质参数。
class GlassSpec {
  final Color tint; // 着色（rgb 用；alpha 就是着色强度）
  final double saturation;
  final double thickness; // 折射带宽度 px
  final double refract; // 折射位移 px
  final double light; // 亮边强度
  const GlassSpec({required this.tint, this.saturation = 1.45, this.thickness = 14, this.refract = 9, this.light = 0.5});

  GlassSpec copyWith({Color? tint}) => GlassSpec(tint: tint ?? this.tint, saturation: saturation, thickness: thickness, refract: refract, light: light);
}

/// setFloat 的下标：按 glass.frag 里 float 类 uniform 的声明顺序（sampler 不计）。
class _U {
  static const size = 0, origin = 2, rect = 4, radius = 6, mode = 7, tint = 8, saturation = 12, thickness = 13, refract = 14, light = 15, screen = 16;
}

void _setCommon(ui.FragmentShader s, GlassSpec spec, double radius, double mode) {
  s
    ..setFloat(_U.radius, radius)
    ..setFloat(_U.mode, mode)
    ..setFloat(_U.tint, spec.tint.r)
    ..setFloat(_U.tint + 1, spec.tint.g)
    ..setFloat(_U.tint + 2, spec.tint.b)
    ..setFloat(_U.tint + 3, spec.tint.a)
    ..setFloat(_U.saturation, spec.saturation)
    ..setFloat(_U.thickness, spec.thickness)
    ..setFloat(_U.refract, spec.refract)
    ..setFloat(_U.light, spec.light);
}

// ------------------------------------------------------------------ 预模糊背景

/// 截好并模糊过的全局背景 + 它的逻辑尺寸 + 平均亮度（背景暗的时候卡片着色要加重，字才看得清）。
class GlassBackdropData {
  final ui.Image image;
  final Size logicalSize;
  final double luma;
  const GlassBackdropData({required this.image, required this.logicalSize, required this.luma});
}

/// 全局背景层的宿主：把背景截一次图、模糊一次，给所有 [GlassSurface] 取样。
/// [signature] 变了（主题 / 强调色 / 背景图 / 可见度）或屏幕尺寸变了就重截。
class GlassBackdrop extends StatefulWidget {
  final Widget background;
  final Widget child;
  final Object signature;
  final double sigma;
  /// 截图前先把背景图解码好（不然第一帧截到的是没图的底）。
  final Future<void> Function(BuildContext context)? warmUp;
  const GlassBackdrop({super.key, required this.background, required this.child, required this.signature, this.sigma = 22, this.warmUp});

  static GlassBackdropData? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_GlassBackdropScope>()?.notifier?.value;

  static ValueListenable<GlassBackdropData?>? listenableOf(BuildContext context) => context.getInheritedWidgetOfExactType<_GlassBackdropScope>()?.notifier;

  @override
  State<GlassBackdrop> createState() => _GlassBackdropState();
}

class _GlassBackdropState extends State<GlassBackdrop> with WidgetsBindingObserver {
  final _key = GlobalKey();
  final _data = ValueNotifier<GlassBackdropData?>(null);
  var _gen = 0;
  Size? _capturedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(GlassBackdrop old) {
    super.didUpdateWidget(old);
    if (old.signature != widget.signature || old.sigma != widget.sigma) _schedule();
  }

  @override
  void didChangeMetrics() => _schedule();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gen++;
    _data.value?.image.dispose();
    _data.dispose();
    super.dispose();
  }

  void _schedule() {
    final gen = ++_gen;
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture(gen));
  }

  Future<void> _capture(int gen) async {
    if (!mounted || gen != _gen) return;
    try {
      await widget.warmUp?.call(context);
      if (!mounted || gen != _gen) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || gen != _gen) return;
      final ro = _key.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary || ro.size.isEmpty) return;
      final logical = ro.size;
      const scale = 0.5; // 模糊过的图不需要满分辨率
      final shot = await ro.toImage(pixelRatio: scale);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImage(shot, Offset.zero, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: widget.sigma * scale, sigmaY: widget.sigma * scale, tileMode: TileMode.clamp));
      final blurred = await rec.endRecording().toImage(shot.width, shot.height);
      final luma = await _meanLuma(shot);
      shot.dispose();
      if (!mounted || gen != _gen) {
        blurred.dispose();
        return;
      }
      final old = _data.value;
      _data.value = GlassBackdropData(image: blurred, logicalSize: logical, luma: luma);
      _capturedFor = logical;
      // 下一帧之后再释放旧图：本帧可能还有卡片在用它画
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.image.dispose());
    } catch (e) {
      debugPrint('glass backdrop capture failed: $e');
    }
  }

  static Future<double> _meanLuma(ui.Image img) async {
    // 缩到很小再算平均，几百个像素而已
    final rec = ui.PictureRecorder();
    const w = 16, h = 32;
    Canvas(rec).drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), const Rect.fromLTWH(0, 0, w * 1.0, h * 1.0), Paint()..filterQuality = FilterQuality.low);
    final small = await rec.endRecording().toImage(w, h);
    final bytes = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    small.dispose();
    if (bytes == null) return 0.85;
    var sum = 0.0;
    final n = bytes.lengthInBytes ~/ 4;
    for (var i = 0; i < n; i++) {
      sum += 0.2126 * bytes.getUint8(i * 4) + 0.7152 * bytes.getUint8(i * 4 + 1) + 0.0722 * bytes.getUint8(i * 4 + 2);
    }
    return n == 0 ? 0.85 : sum / n / 255.0;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: RepaintBoundary(key: _key, child: widget.background)),
      Positioned.fill(child: _GlassBackdropScope(notifier: _data, child: _SizeWatcher(onSize: _onSize, child: widget.child))),
    ]);
  }

  void _onSize(Size s, Offset _) {
    if (_capturedFor != null && _capturedFor != s) _schedule();
  }
}

class _GlassBackdropScope extends InheritedNotifier<ValueNotifier<GlassBackdropData?>> {
  const _GlassBackdropScope({required ValueNotifier<GlassBackdropData?> notifier, required super.child}) : super(notifier: notifier);
}

/// 布局尺寸变了（旋转 / 分屏 / 底栏高度）在帧后通知一下：尺寸 + 当时的屏幕坐标。
class _SizeWatcher extends SingleChildRenderObjectWidget {
  final void Function(Size size, Offset origin) onSize;
  const _SizeWatcher({required this.onSize, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeWatcher(onSize);
  @override
  void updateRenderObject(BuildContext context, _RenderSizeWatcher renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeWatcher extends RenderProxyBox {
  void Function(Size size, Offset origin) onSize;
  Size? _last;
  _RenderSizeWatcher(this.onSize);
  @override
  void performLayout() {
    super.performLayout();
    if (_last != size) {
      _last = size;
      final s = size;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) onSize(s, localToGlobal(Offset.zero));
      });
    }
  }
}

// ------------------------------------------------------------------ 内容卡片：静态背景取样

/// 画在内容卡片底下的玻璃面：从 [GlassBackdrop] 的预模糊图上按自己在屏幕上的位置取样，加折射 / 饱和 / 着色 / 亮边。
/// 跟着所有祖先滚动位置重画，玻璃里的背景才钉在屏幕上、不跟卡片一起走。
/// 没有着色器 / 背景还没截好时退回半透明填充。
class GlassSurface extends StatefulWidget {
  final Widget? child;
  final double radius;
  final GlassSpec spec;
  final Color fallback;
  const GlassSurface({super.key, this.child, required this.radius, required this.spec, required this.fallback});

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  ui.FragmentShader? _shader;
  Listenable? _repaint;

  @override
  void initState() {
    super.initState();
    _shader = GlassShaders.create();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final deps = <Listenable?>[GlassBackdrop.listenableOf(context)];
    ScrollableState? s = Scrollable.maybeOf(context);
    while (s != null) {
      deps.add(s.position);
      s = Scrollable.maybeOf(s.context);
    }
    _repaint = Listenable.merge(deps);
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GlassSurfacePainter(context: context, shader: _shader, spec: widget.spec, radius: widget.radius, fallback: widget.fallback, repaint: _repaint),
      child: widget.child,
    );
  }
}

class _GlassSurfacePainter extends CustomPainter {
  final BuildContext context;
  final ui.FragmentShader? shader;
  final GlassSpec spec;
  final double radius;
  final Color fallback;
  _GlassSurfacePainter({required this.context, required this.shader, required this.spec, required this.radius, required this.fallback, super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final data = GlassBackdrop.listenableOf(context)?.value;
    final s = shader;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    if (s == null || data == null) {
      canvas.drawRRect(rrect, Paint()..color = fallback);
      return;
    }
    final box = context.findRenderObject();
    final origin = box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) : Offset.zero;
    // 背景暗 → 着色加重，深色字才读得出；亮背景保持通透
    final tint = spec.tint.withValues(alpha: (spec.tint.a + (0.62 - data.luma).clamp(0.0, 0.5) * 0.7).clamp(0.0, 0.85));
    s
      ..setFloat(_U.size, data.logicalSize.width)
      ..setFloat(_U.size + 1, data.logicalSize.height)
      ..setFloat(_U.origin, origin.dx)
      ..setFloat(_U.origin + 1, origin.dy)
      ..setFloat(_U.rect, size.width)
      ..setFloat(_U.rect + 1, size.height)
      ..setImageSampler(0, data.image);
    _setCommon(s, spec.copyWith(tint: tint), radius, 1);
    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(_GlassSurfacePainter old) => true; // 一次 drawRect，重画不值一提
}

// ------------------------------------------------------------------ 真悬浮层：BackdropFilter

/// 真玻璃（底栏这种内容会从底下滚过的悬浮层）：Impeller 上 = 模糊 + 着色器折射；否则模糊 + 半透明填充。
/// 形状一律胶囊 / 圆角矩形，外面自己包 ClipRRect。
/// 自己量尺寸和屏幕坐标：页面切换时整页被套进透明度层，着色器拿到的纹理会变成整屏，靠它把形状定位回去。
class LiquidGlass extends StatefulWidget {
  final Widget child;
  final GlassSpec spec;
  final double radius;
  final double blur;
  final Color fallback;
  const LiquidGlass({super.key, required this.child, required this.spec, required this.radius, this.blur = 18, required this.fallback});

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  ui.FragmentShader? _shader;
  Size? _size;
  Offset _origin = Offset.zero;

  void _measured(Size s, Offset o) {
    if (!mounted || (s == _size && o == _origin)) return;
    setState(() {
      _size = s;
      _origin = o;
    });
  }

  @override
  void initState() {
    super.initState();
    if (GlassShaders.backdropSupported) _shader = GlassShaders.create();
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blur = ui.ImageFilter.blur(sigmaX: widget.blur, sigmaY: widget.blur, tileMode: TileMode.clamp);
    final s = _shader;
    if (s == null) {
      return BackdropFilter(filter: blur, child: DecoratedBox(decoration: BoxDecoration(color: widget.fallback), child: widget.child));
    }
    final screen = MediaQuery.sizeOf(context);
    final size = _size ?? Size(screen.width, 64); // 第一帧还没量到，先按整宽估；量到后下一帧就准
    s
      ..setFloat(_U.origin, _origin.dx)
      ..setFloat(_U.origin + 1, _origin.dy)
      ..setFloat(_U.rect, size.width)
      ..setFloat(_U.rect + 1, size.height)
      ..setFloat(_U.screen, screen.width)
      ..setFloat(_U.screen + 1, screen.height);
    _setCommon(s, widget.spec, widget.radius, 0);
    return _SizeWatcher(
      onSize: _measured,
      child: BackdropFilter(filter: ui.ImageFilter.compose(outer: ui.ImageFilter.shader(s), inner: blur), child: widget.child),
    );
  }
}
