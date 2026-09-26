import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../game/cheer.dart';
import '../theme.dart';

/// 首页头卡底下的寄语轮播：收入排位（低于三成不在首页亮）+ 按处境挑的一池话，每 [interval] 淡入淡出换一句，点一下立刻换。
/// 看不见的时候（切到别的标签页、被路由盖住）不换，省得白白重建。
class CheerCarousel extends StatefulWidget {
  final WealthMetrics m;
  final Duration interval;
  const CheerCarousel({super.key, required this.m, this.interval = const Duration(seconds: 7)});

  @override
  State<CheerCarousel> createState() => _CheerCarouselState();
}

class _CheerCarouselState extends State<CheerCarousel> {
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) => _next(auto: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _next({bool auto = false}) {
    if (!mounted) return;
    if (auto && !TickerMode.getValuesNotifier(context).value.enabled) return; // 不在屏幕上：不换（getValuesNotifier 不注册依赖，定时器回调里可以用）
    setState(() => _step++);
  }

  @override
  Widget build(BuildContext context) {
    final tone = cheerToneFor(widget.m);
    if (tone == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final pool = cheerLines(tone);
    final line = pool[(cheerStartIndex(widget.m.today, pool.length) + _step) % pool.length];
    final rank = widget.m.incomeRank != null && widget.m.incomeRank!.percentile >= 0.3 ? incomeRankLine(widget.m) : null;
    final color = tone == CheerTone.abundant ? y.income : y.muted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _next,
      child: Semantics(
        label: [?rank, line].join('，'),
        button: true,
        hint: '点一下换一句',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (rank != null) Text(rank, style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
            // 会变的这句用人格的主题色（换人格跟着换）；上面那行收入排位不变色
            child: Text(line, key: ValueKey(line), style: theme.textTheme.bodySmall?.copyWith(color: personaLineColor(context)), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
    );
  }
}

/// 人格主题色，按当前深浅色调到看得清：浅色主题里太浅的（自定义人格可能选了浅黄）压暗，深色主题里太深的提亮。
Color personaLineColor(BuildContext context) {
  final base = Color(0xFF000000 | AppScope.of(context).persona.accent);
  final lum = base.computeLuminance();
  if (Theme.of(context).brightness == Brightness.dark) {
    return lum < 0.35 ? Color.lerp(base, const Color(0xFFFFFFFF), 0.4)! : base;
  }
  return lum > 0.45 ? Color.lerp(base, const Color(0xFF000000), 0.45)! : base;
}
