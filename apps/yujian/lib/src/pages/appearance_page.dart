import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

/// 外观：主题。点了就生效。
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
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
                    decoration: BoxDecoration(color: y.cardFill, borderRadius: BorderRadius.circular(y.radius / 2), border: Border.all(color: y.cardBorder, width: spec.id == 'cartoon' ? 1.5 : 0.6)),
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
