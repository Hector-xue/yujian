import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'fmt.dart';
import 'learn_template_sheet.dart' show noticeAppName;

/// 一条待确认记录是从哪来的：一句话标签 + 详情里的几行原始线索 + 不想再要时去哪关。
/// 草稿不跨设备同步，都是这台手机上某条路径生成的，所以每一条都能追到具体来源。
class DraftOrigin {
  final IconData icon;
  final String label; // 卡片上那一行：「微信通知」「截图 Screenshot_…」「周期账单「房租」到期」
  final List<(String, String)> details; // 详情页的「字段：值」
  final String? hint; // 不想要这类时怎么办
  const DraftOrigin(this.icon, this.label, this.details, [this.hint]);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// 本地时间精确到秒：「2026-09-25 10:32:05」。
String fmtExactTime(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

DraftOrigin describeDraftOrigin(AppState app, Draft d) {
  final meta = (d.payload['metadata'] as Map?)?.cast<String, Object?>() ?? const {};
  final interp = d.interpreter ?? '';
  final model = d.modelUsed;
  final conf = d.confidence == null ? null : '${(d.confidence! * 100).round()}%';
  switch (d.source) {
    case Source.notification:
      final n = (meta['notification'] as Map?)?.cast<String, Object?>() ?? const {};
      final pkg = n['package'] as String?;
      final screen = n['source'] == 'screen';
      final appName = noticeAppName(pkg);
      return DraftOrigin(
        screen ? Icons.phone_android : Icons.notifications_none,
        screen ? '$appName 支付页识别' : '$appName 通知',
        [
          ('来源', screen ? '支付页识别（无障碍）：付款成功那一页上读到的字' : '通知自动记账：系统通知栏里的一条通知'),
          ('应用', pkg == null ? '未知' : '$appName（$pkg）'),
          if ((n['title'] as String?)?.isNotEmpty ?? false) ('标题', n['title'] as String),
          if ((n['text'] as String?)?.isNotEmpty ?? false) ('原文', n['text'] as String),
          ('认法', '本机模板 ${n['template'] ?? interp.replaceFirst('notification:', '')}，不经过模型'),
          if (conf != null) ('把握', conf),
        ],
        screen
            ? '不是一笔账就点「忽略」。支付页识别可以在 更多 → 自动记账 里关掉。'
            : '不是一笔账就点「忽略」。认错了可以在 更多 → 自动记账 →「教它认一种通知」里纠正；这个 App 的通知都不想要，就在那里关掉通知自动记账。',
      );
    case Source.screenshot:
      final s = (meta['screenshot'] as Map?)?.cast<String, Object?>() ?? const {};
      final how = (s['how'] as String?) ?? interp;
      final added = (s['added_ms'] as num?)?.toInt();
      return DraftOrigin(
        Icons.image_outlined,
        '截图 ${s['name'] ?? ''}'.trim(),
        [
          ('来源', '截图自动记账：相册里新出现的一张截图'),
          if (s['name'] != null) ('图片', '${s['name']}'),
          if (added != null && added > 0) ('截图时间', fmtExactTime(DateTime.fromMillisecondsSinceEpoch(added))),
          ('认法', switch (how) {
            'ocr:local' => '本机 OCR + 规则，图和字都没出手机',
            'ocr:text' => '本机 OCR，文字打码后交给模型${model == null ? '' : '（$model）'}',
            'vision:auto' => '原图交给看图模型${model == null ? '' : '（$model）'}',
            _ => how,
          }),
          if (conf != null) ('把握', conf),
        ],
        '不是一笔账就点「忽略」。截图自动记账可以在 更多 → 自动记账 里关掉，或把「截图怎么认」调回「仅本机」。',
      );
    case Source.recurring:
      if (interp == 'payday') {
        return DraftOrigin(Icons.savings_outlined, '发薪日分钱', [
          ('来源', '工资到账后，按你给目标设的「每月定存 / 工资到账存 %」生成的转账'),
          if (d.payload['description'] != null) ('说明', '${d.payload['description']}'),
        ], '目标用的是真账户，要你自己转过去再确认；不想每月自动提议，去目标详情里改存入规则。');
      }
      if (interp == 'goal') {
        final g = meta['goal_id'] is String ? app.ledger.goals.find(meta['goal_id'] as String) : null;
        return DraftOrigin(Icons.flag_outlined, g == null ? '目标定期存入' : '目标「${g.name}」定期存入', [
          ('来源', '目标的存入规则（定额 / 零头凑整 / 周任务奖励）到点生成'),
          if (d.payload['description'] != null) ('说明', '${d.payload['description']}'),
        ], '这个目标的钱放在真账户里，所以要你转完再确认；不想要了去目标详情改规则。');
      }
      final rid = RegExp(r'^recurring:([^:]+):').firstMatch(d.eventFingerprint ?? '')?.group(1);
      String? name;
      if (rid != null) {
        try {
          name = app.ledger.recurring.get(rid).name;
        } catch (_) {}
      }
      return DraftOrigin(Icons.event_repeat, name == null ? '周期账单到期' : '周期账单「$name」到期', [
        ('来源', '你设的周期账单到了这一期，自动生成一笔等你确认'),
        if (name != null) ('账单', name),
      ], '这期已经付过或不用付就点「忽略」；不想再生成，去 更多 → 周期账单，用右侧开关暂停，或长按删除。');
    case Source.chat:
      return DraftOrigin(Icons.chat_bubble_outline, '对话里说的', [
        ('来源', '你在对话里说的一句话'),
        ('认法', interp.startsWith('rule') || interp.isEmpty ? '本机规则' : '模型${model == null ? '' : '（$model）'}'),
        if (conf != null) ('把握', conf),
      ]);
    case Source.import_:
      return const DraftOrigin(Icons.file_download_outlined, '导入的账单', [('来源', '你导入的账单文件里的一行')]);
    case Source.share:
      return const DraftOrigin(Icons.share_outlined, '分享进来的', [('来源', '从别的 App 分享给余见的文字或图片')]);
    case Source.mcp:
      return const DraftOrigin(Icons.hub_outlined, '外部 Agent（MCP）', [('来源', '你接入的 Agent 通过 MCP 提议的一笔')], '不认识这个来源，就检查自己配过的 MCP 客户端。');
    case Source.manual:
      if (interp == 'goal') {
        return const DraftOrigin(Icons.flag_outlined, '目标存入', [('来源', '你手动往一个用真账户存钱的目标里存了一笔')], '去银行 / 余额宝真转了再点确认。');
      }
      return const DraftOrigin(Icons.edit_outlined, '手动', [('来源', '你手动添加的')]);
  }
}

/// 卡片上那一行：图标 + 来源 + 多久前进来的；点开看详情。
class DraftOriginLine extends StatelessWidget {
  final Draft draft;
  const DraftOriginLine({super.key, required this.draft});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final o = describeDraftOrigin(app, draft);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showDraftOrigin(context, draft),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(o.icon, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${o.label} · ${fmtRelativeMs(draft.createdAt.millisecondsSinceEpoch)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
          Text('从哪来的', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
        ]),
      ),
    );
  }
}

/// 详情：确切时间、原始线索、疑似和哪笔重复、不想要时去哪关。
Future<void> showDraftOrigin(BuildContext context, Draft d) {
  final app = AppScope.of(context);
  final o = describeDraftOrigin(app, d);
  Transaction? dup;
  if (d.possibleDuplicateOf != null) {
    try {
      dup = app.ledger.transaction(d.possibleDuplicateOf!);
    } catch (_) {}
  }
  final rows = <(String, String)>[
    ('进入收件箱', fmtExactTime(d.createdAt)),
    ...o.details,
    if (dup != null) ('疑似重复', '和 ${dup.occurredAt.localDate} 的「${dup.description ?? app.categoryName(dup.categoryId)}」金额、时间很接近'),
  ];
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final y = YujianColors.of(ctx);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(children: [
              Icon(o.icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(o.label, style: theme.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 12),
            for (final (k, v) in rows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: y.hairline, width: 0.6))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 76, child: Text(k, style: theme.textTheme.bodySmall?.copyWith(color: y.muted))),
                  Expanded(child: SelectableText(v, style: theme.textTheme.bodyMedium)),
                ]),
              ),
            if (o.hint != null) ...[
              const SizedBox(height: 12),
              Text(o.hint!, style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
            ],
          ],
        ),
      );
    },
  );
}
