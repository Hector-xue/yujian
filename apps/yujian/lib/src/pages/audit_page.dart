import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import 'net_log_page.dart';

/// 审计日志：账本的每一次改动（谁改的、改了什么、有没有经你确认）。
/// 它只管账本；软件和外界的每一次通信在「出网记录」里，这里顶上给一个入口。
class AuditPage extends StatelessWidget {
  const AuditPage({super.key});

  /// 动作名 → 大白话。
  static String actionText(AuditEntry e) {
    final a = e.after ?? const {};
    final amount = a['amount_minor'] is num ? fmtMoney((a['amount_minor'] as num).toInt(), (a['currency'] as String?) ?? 'CNY') : null;
    final desc = (a['description'] ?? a['merchant'] ?? a['name']) as String?;
    final tail = [?amount, if (desc != null && desc.isNotEmpty) desc].join(' · ');
    final what = tail.isEmpty ? '' : '：$tail';
    return switch (e.action) {
      'account.create' => '新建账户$what',
      'account.update' => '修改账户$what',
      'account.archive' => '归档账户',
      'account.unarchive' => '恢复账户',
      'category.create' => '新建分类$what',
      'category.update' => '修改分类$what',
      'category.delete' => '删除分类',
      'draft.propose' => '${_who(e)}提了一笔草稿进收件箱$what',
      'draft.dedupe' => '${_who(e)}发现这笔和已有的一模一样，没重复起草',
      'draft.commit' => '你确认了收件箱里的一笔，已入账$what',
      'draft.dismiss' => '你忽略了收件箱里的一笔',
      'transaction.create' => '记了一笔$what',
      'transaction.update' => '改了一笔$what',
      'transaction.void' => '作废了一笔',
      'ledger.restore' => '从备份整体恢复了账本（${a['transactions'] ?? '?'} 笔）',
      'sync.apply' => '同步：应用了另一台设备（${_dev(a['from'])}）的改动',
      'sync.conflict_skipped' => '同步：两台设备改了同一笔，本机的更新，跳过了对方的',
      _ => e.action,
    };
  }

  static String _who(AuditEntry e) => switch (e.actor) {
        Actor.user => '你',
        Actor.interpreter => '模型',
        Actor.automation => '自动记账',
        Actor.mcp => '外部 Agent（MCP）',
      };

  static String _dev(Object? v) {
    final s = '$v';
    return s.length > 6 ? s.substring(s.length - 6) : s;
  }

  static String _how(AuditEntry e) {
    final i = e.interpreter ?? '';
    if (i.startsWith('notification:')) return '通知 / 支付页自动记账（本机模板 ${i.substring(13)}）';
    final base = switch (i) {
      'rule' => '本机规则',
      'llm' => '模型解析',
      'hybrid' => '规则 + 模型',
      'vision' => '看图模型',
      'vision:auto' => '截图自动记账（发原图）',
      'ocr:local' => '截图自动记账（本机 OCR）',
      'ocr:text' => '截图自动记账（发文字）',
      'template' => '通知模板（本机）',
      'import' => '导入文件',
      '' => '',
      _ => i,
    };
    return [if (base.isNotEmpty) base, if (e.modelUsed != null) e.modelUsed!].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    final log = app.ledger.auditLog(limit: 300);
    final byDay = <String, List<AuditEntry>>{};
    for (final e in log) {
      final d = e.at.toLocal();
      byDay.putIfAbsent('${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}', () => []).add(e);
    }
    final today = todayLocal();
    return Scaffold(
      appBar: AppBar(title: const Text('审计日志')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text('这里记账本的每一次改动：谁改的、改了什么、有没有经你确认（✓）。模型和自动记账只能提草稿，入账都要你点过。', style: theme.textTheme.bodySmall),
          ),
          GlassCard(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            child: ListTile(
              leading: Icon(Icons.public, color: theme.colorScheme.primary),
              title: const Text('出网记录'),
              subtitle: Text('这份日志只管账本。软件和外界的每一次通信（发给模型什么、同步了什么）在出网记录里', style: theme.textTheme.bodySmall),
              trailing: Icon(Icons.chevron_right, color: muted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NetLogPage())),
            ),
          ),
          if (log.isEmpty)
            Padding(padding: const EdgeInsets.all(20), child: Text('还没有改动', style: theme.textTheme.bodySmall))
          else
            // 按天一组一张卡（和「记录」页同款）。以前 300 条塞在一张卡的 Column 里：ListView 只对它的直接子项懒加载，
            // 一张卡 = 一个子项，进页第一帧就得把 300 个 ListTile 全建全排，那一帧长到把整段转场动画吃掉——看起来就是「没动画」。
            // 拆成一天一张卡后只有露出来的几张真正建出来；一天太多条再切成几张卡，一张最多 _chunk 条。
            for (final day in byDay.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 6),
                child: Text(fmtDate(day.key, today: today), style: theme.textTheme.bodySmall),
              ),
              for (var i = 0; i < day.value.length; i += _chunk)
                GlassCard(
                  margin: EdgeInsets.fromLTRB(20, i == 0 ? 0 : 8, 20, 0),
                  child: Column(children: [for (final e in day.value.sublist(i, i + _chunk > day.value.length ? day.value.length : i + _chunk)) _AuditRow(e: e)]),
                ),
            ],
        ],
      ),
    );
  }

  static const _chunk = 40;
}

class _AuditRow extends StatelessWidget {
  final AuditEntry e;
  const _AuditRow({required this.e});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = e.at.toLocal();
    final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final how = AuditPage._how(e);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text('${AuditPage.actionText(e)}${e.confirmedByUser ? ' ✓' : ''}'),
      subtitle: Text('$hm · ${AuditPage._who(e)}${how.isNotEmpty ? ' · $how' : ''}', style: theme.textTheme.bodySmall),
    );
  }
}
