import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'category_icon.dart';
import 'draft_edit_sheet.dart';
import 'fmt.dart';

/// 一组草稿（同 group_id）的确认卡：逐条可改，可整组确认/忽略。对话页和收件箱共用。
class DraftGroupCard extends StatelessWidget {
  final List<Draft> drafts;
  final VoidCallback? onChanged;
  final void Function(int committed)? onCommitted;
  const DraftGroupCard({super.key, required this.drafts, this.onChanged, this.onCommitted});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pending = drafts.where((d) => d.status == DraftStatus.pending).toList();
    final committed = drafts.where((d) => d.status == DraftStatus.committed).length;
    final theme = Theme.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final d in drafts) _DraftRow(draft: d, onChanged: onChanged, onCommitted: onCommitted),
            if (pending.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  if (pending.any((d) => d.missingFields.isNotEmpty)) Expanded(child: Text('还缺字段，点条目补全后再确认', style: theme.textTheme.bodySmall)) else const Spacer(),
                  TextButton(
                    onPressed: () {
                      app.dismissGroup(drafts.first.groupId);
                      onChanged?.call();
                    },
                    child: const Text('忽略'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: pending.any((d) => d.missingFields.isNotEmpty)
                        ? null
                        : () {
                            try {
                              final n = app.commitGroup(drafts.first.groupId).length; // 卡片自己会变成"已记账 N 笔"，不弹条挡输入框
                              onCommitted?.call(n);
                            } on LedgerException catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                            }
                            onChanged?.call();
                          },
                    child: Text(pending.length > 1 ? '全部确认' : '确认'),
                  ),
                ],
              ),
            ] else if (committed > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('已记账 $committed 笔', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class _DraftRow extends StatelessWidget {
  final Draft draft;
  final VoidCallback? onChanged;
  final void Function(int committed)? onCommitted;
  const _DraftRow({required this.draft, this.onChanged, this.onCommitted});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final p = draft.payload;
    final done = draft.status != DraftStatus.pending;
    String title;
    String subtitle;
    switch (draft.kind) {
      case DraftKind.create:
        final amount = p['amount_minor'] is int ? fmtMoney(p['amount_minor'] as int, (p['currency'] as String?) ?? 'CNY') : '金额？';
        final type = (p['type'] as String?) ?? 'expense';
        final where = type == 'transfer'
            ? '${app.accountName(p['account_id'] as String?)} → ${app.accountName(p['to_account_id'] as String?)}'
            : '${app.categoryName(p['category_id'] as String?)} · ${app.accountName(p['account_id'] as String?)}';
        final when = p['occurred_at'] is String ? OccurredAt.parse(p['occurred_at'] as String) : null;
        title = '${typeLabel(type)} $amount';
        subtitle = '$where${when != null ? ' · ${fmtDate(when.localDate, today: todayLocal())}' : ''}${p['description'] != null ? ' · ${p['description']}' : ''}';
      case DraftKind.update:
        title = '修改交易';
        subtitle = p.entries.map((e) => '${e.key} → ${e.value}').join('，');
      case DraftKind.void_:
        title = '作废交易';
        subtitle = (p['reason'] as String?) ?? '';
    }
    final flags = <String>[
      if (draft.missingFields.isNotEmpty) '缺 ${draft.missingFields.map(_fieldName).join('、')}',
      if (draft.possibleDuplicateOf != null) '疑似重复',
    ];
    return InkWell(
      onTap: done || draft.kind != DraftKind.create
          ? null
          : () async {
              final edits = await showDraftEditSheet(context, draft);
              if (edits == null || !context.mounted) return;
              try {
                app.commit(draft.id, edits: edits);
                onCommitted?.call(1);
              } on LedgerException catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
              }
              onChanged?.call();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            if (draft.kind == DraftKind.create) ...[
              CategoryIcon(category: p['category_id'] is String ? app.ledger.category(p['category_id'] as String) : null, size: 36, fallback: p['type'] == 'transfer' ? '🔁' : null),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(color: done ? theme.textTheme.bodySmall?.color : null)),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                  if (flags.isNotEmpty) Text(flags.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: YujianColors.of(context).danger)),
                ],
              ),
            ),
            if (done)
              Icon(draft.status == DraftStatus.committed ? Icons.check : Icons.close, size: 18, color: theme.textTheme.bodySmall?.color)
            else
              Icon(Icons.chevron_right, size: 18, color: YujianColors.of(context).muted),
          ],
        ),
      ),
    );
  }

  static String _fieldName(String f) => switch (f) {
        'account_id' => '账户',
        'to_account_id' => '转入账户',
        'category_id' => '分类',
        'amount_minor' => '金额',
        'occurred_at' => '时间',
        'currency' => '币种',
        'refund_of_id' => '原交易',
        'description' => '说明',
        _ => f,
      };
}
