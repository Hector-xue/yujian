import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../platform/avatar_files_native.dart' if (dart.library.js_interop) '../platform/avatar_files_web.dart';
import '../theme.dart';

/// 外观：主题 + 自定义全局背景图（可调可见度）。点了就生效。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});
  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  double? _dragging; // 滑块拖动中的临时值，松手才落盘

  Future<void> _pickBackground() async {
    final app = AppScope.of(context);
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, maxHeight: 2400, imageQuality: 85);
    if (x == null) return;
    await app.setBackground(await x.readAsBytes(), ext: x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final s = app.settings;
    final bgPath = s.backgroundImage ?? '';
    final bg = bgPath.isEmpty ? null : backgroundImage(bgPath);
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('背景', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('用自己的图片当全屏背景，所有页面都在它上面。可见度调低一点字更清楚。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          if (bg == null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(onPressed: _pickBackground, icon: const Icon(Icons.wallpaper_outlined, size: 18), label: const Text('从相册选一张')),
            )
          else ...[
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(width: 96, height: 160, child: Opacity(opacity: (_dragging ?? s.backgroundOpacity).clamp(0.0, 1.0), child: bg)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('可见度 ${((_dragging ?? s.backgroundOpacity) * 100).round()}%', style: theme.textTheme.bodyMedium),
                  Slider(
                    value: (_dragging ?? s.backgroundOpacity).clamp(0.05, 1.0),
                    min: 0.05,
                    max: 1,
                    onChanged: (v) => setState(() => _dragging = v),
                    onChangeEnd: (v) async {
                      await app.saveSettings(app.settings.copyWith(backgroundOpacity: v));
                      if (mounted) setState(() => _dragging = null);
                    },
                  ),
                  Wrap(spacing: 8, children: [
                    OutlinedButton(onPressed: _pickBackground, child: const Text('换一张')),
                    TextButton(onPressed: () => app.setBackground(null), child: const Text('移除')),
                  ]),
                ]),
              ),
            ]),
          ],
          const SizedBox(height: 24),
          Text('主题', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('主题管质感和形状，强调色跟人格走。点了就生效。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisExtent: 118, crossAxisSpacing: 10, mainAxisSpacing: 10),
            itemCount: appThemes.length,
            itemBuilder: (ctx, i) => _ThemeCard(
                spec: appThemes[i],
                accent: theme.colorScheme.primary,
                selected: app.settings.themeId == appThemes[i].id,
                onTap: () => app.saveSettings(app.settings.copyWith(themeId: appThemes[i].id))),
          ),
        ],
      ),
    );
  }
}

/// 主题预览卡：用该主题自己的 ThemeData 画一个小样，所见即所得。
class _ThemeCard extends StatelessWidget {
  final AppThemeSpec spec;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeCard({required this.spec, required this.accent, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = spec.build(accent);
    final y = t.extension<YujianColors>()!;
    final outer = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? outer.colorScheme.primary : outer.dividerTheme.color ?? Colors.black12, width: selected ? 2 : 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(child: spec.background?.call(context, accent) ?? ColoredBox(color: t.scaffoldBackgroundColor)),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    // 实色主题把自己的描边 / 投影也画出来（硬影、双向光影一眼能认）；玻璃主题只画底色 + 细边
                    decoration: BoxDecoration(
                      color: y.cardFill,
                      borderRadius: BorderRadius.circular(y.radius / 2),
                      border: y.borderWidth > 0 || spec.id == 'cartoon' ? Border.all(color: y.cardBorder, width: spec.id == 'cartoon' ? 1.5 : y.borderWidth) : null,
                      boxShadow: y.glass ? null : (y.shadows ?? const []).map((b) => b.scale(0.6)).toList(),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text('¥ 1,280', style: t.textTheme.titleMedium?.copyWith(color: y.balance, fontSize: 13)),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Container(width: 22, height: 8, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4))),
                    const SizedBox(width: 4),
                    Container(width: 14, height: 8, decoration: BoxDecoration(color: y.income, borderRadius: BorderRadius.circular(4))),
                  ]),
                  const Spacer(),
                  Text(spec.name, style: t.textTheme.titleMedium?.copyWith(fontSize: 13)),
                  Text(spec.tagline, style: t.textTheme.bodySmall?.copyWith(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (selected) Positioned(top: 6, right: 6, child: Icon(Icons.check_circle, size: 16, color: outer.colorScheme.primary)),
          ],
        ),
      ),
    );
  }
}
