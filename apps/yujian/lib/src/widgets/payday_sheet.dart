import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import 'fmt.dart';
import 'picker_field.dart';

/// 发薪日现在按什么算，一句话：「每月 10、25 号（你填的）」「每月 10 号（从工资记录推的）」「还不知道，按月底估」。
String paydaySummary(AppState app) {
  final s = Paydays(app.ledger).schedule(today: todayLocal());
  if (s.days.isEmpty) return '还不知道，按每月月底估';
  final days = '每月 ${s.days.join('、')} 号';
  return s.source == PaydaySource.profile ? '$days（你填的）' : '$days（从工资记录推的）';
}

/// 发薪日设置：自动推断 / 手动选（可以几个：工资、绩效分开发就选两天），工资到哪个账户。
/// 首页「几天后发薪」、日历上的发薪日、「更多 → 规划」、财富页都打开这一个。
Future<void> showPaydaySheet(BuildContext context) async {
  final app = AppScope.of(context);
  final profile = app.ledger.profile;
  final today = todayLocal();
  final pays = Paydays(app.ledger);
  final inferred = [...pays.infer(today: today)]..sort(); // infer 可能返回常量空列表，先拷一份再排
  final next = pays.next(today: today);
  var manual = profile.paydays.isNotEmpty;
  final picked = <int>{...profile.paydays};
  String? salaryAccount = app.accounts.any((a) => a.id == profile.salaryAccountId) ? profile.salaryAccountId : null;
  String? error;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        final muted = theme.textTheme.bodySmall;
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('发薪日', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                next.isLate
                    ? '本该 ${fmtMd(next.lateSince!)} 发，到现在还没到账；按明天会到估。'
                    : '下次发薪 ${fmtMd(next.date)}。「可花的」「今天还能花」都按到这天为止算。',
                style: muted,
              ),
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('自动推断')), ButtonSegment(value: true, label: Text('我来选'))],
                selected: {manual},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() {
                  manual = v.first;
                  error = null;
                  if (manual && picked.isEmpty && inferred.isNotEmpty) picked.addAll(inferred);
                }),
              ),
              const SizedBox(height: 10),
              if (!manual)
                Text(
                  inferred.isEmpty
                      ? '还推不出来：没有「工资 / 奖金」的收入记录。记一笔工资就能推出来，推出来之前按每月月底估。'
                      : '按工资记录推的：每月 ${inferred.join('、')} 号。工资、绩效连着两三个月在不同日子到，会推出两个。',
                  style: muted,
                )
              else ...[
                Text('点选每月几号发薪，可以选几个（工资、绩效分开发就选两个）。没有 31 号的月份按月底。', style: muted),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var d = 1; d <= 31; d++)
                    FilterChip(
                      label: Text('$d'),
                      selected: picked.contains(d),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) => setState(() {
                        error = null;
                        if (on) {
                          if (picked.length >= 3) {
                            error = '最多选 3 天';
                            return;
                          }
                          picked.add(d);
                        } else {
                          picked.remove(d);
                        }
                      }),
                    ),
                ]),
                if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error!, style: muted?.copyWith(color: theme.colorScheme.error))),
              ],
              const SizedBox(height: 16),
              PickerField<String?>(
                value: salaryAccount,
                decoration: const InputDecoration(labelText: '工资到哪个账户'),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('不指定')), for (final a in app.accounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name))],
                onChanged: (v) => setState(() => salaryAccount = v),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (manual && picked.isEmpty) {
                      setState(() => error = '至少选一天，或者改回「自动推断」');
                      return;
                    }
                    profile.paydays = manual ? picked.toList() : const [];
                    profile.salaryAccountId = salaryAccount;
                    app.touch();
                    Navigator.pop(ctx);
                  },
                  child: const Text('保存'),
                ),
              ),
            ]),
          ),
        );
      },
    ),
  );
}
