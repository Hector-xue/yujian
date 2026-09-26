import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import 'picker_field.dart';
import 'category_icon.dart';

/// 手动记一笔：金额 / 类型 / 分类 / 账户 / 时间 / 说明，直接入账（表单本身就是确认）。返回记好的交易。
Future<Transaction?> showManualEntrySheet(BuildContext context, {String type = 'expense'}) {
  // 表单只造这一个实例：键盘升降的每一帧 builder 都会因 viewInsets 变化重跑，传同一个 widget 对象进去 Flutter 就跳过表单的重建，
  // 每帧只动外面那层留位
  final form = _Form(initialType: type);
  return showModalBottomSheet<Transaction>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _KeyboardPad(child: form),
  );
}

/// 给键盘让位的那层。弹层往下收的时候键盘同时在收，留位一帧一帧缩、表单一帧一帧重排，和下滑动画叠在一起就是「收回卡」；
/// 退场期间把留位钉在最后一个值上，表单一动不动，只剩一个滑出动画。
class _KeyboardPad extends StatefulWidget {
  final Widget child;
  const _KeyboardPad({required this.child});
  @override
  State<_KeyboardPad> createState() => _KeyboardPadState();
}

class _KeyboardPadState extends State<_KeyboardPad> {
  double _bottom = 0;
  @override
  Widget build(BuildContext context) {
    final leaving = ModalRoute.of(context)?.animation?.status == AnimationStatus.reverse;
    if (!leaving) _bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(padding: EdgeInsets.only(bottom: _bottom), child: widget.child);
  }
}

class _Form extends StatefulWidget {
  final String initialType;
  const _Form({required this.initialType});
  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  final amount = TextEditingController();
  final desc = TextEditingController();
  late String type = widget.initialType;
  String? categoryId;
  String? accountId;
  String? toAccountId;
  DateTime when = DateTime.now();
  final amountFocus = FocusNode();
  var _focusArmed = false;
  // 分类 / 账户查一次缓存：键盘升起的每一帧都会因 viewInsets 变化重建整张表单，别每帧查库
  List<Category>? _cats;
  CategoryKind? _catsKind;
  List<Account>? _accs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_focusArmed) return;
    _focusArmed = true;
    // 等底部弹层滑到位再叫键盘：弹层动画和键盘动画叠在一起、外加每帧重建表单，就是"弹出略卡"的来源
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusAmount());
      return;
    }
    void onStatus(AnimationStatus st) {
      if (st != AnimationStatus.completed) return;
      anim.removeStatusListener(onStatus);
      _focusAmount();
    }
    anim.addStatusListener(onStatus);
  }

  void _focusAmount() {
    if (mounted) amountFocus.requestFocus();
  }

  @override
  void dispose() {
    amount.dispose();
    desc.dispose();
    amountFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final kind = type == 'income' ? CategoryKind.income : CategoryKind.expense;
    if (_catsKind != kind) {
      _cats = app.ledger.listCategories(kind: kind);
      _catsKind = kind;
    }
    final cats = _cats!;
    final accs = _accs ??= app.ledger.listAccounts();
    accountId ??= app.defaultAccountId ?? (accs.isEmpty ? null : accs.first.id);
    final currency = accs.isEmpty ? 'CNY' : (accs.firstWhere((a) => a.id == accountId, orElse: () => accs.first).currency);
    if (categoryId != null && !cats.any((c) => c.id == categoryId)) categoryId = null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('手动记一笔', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'expense', label: Text('支出')), ButtonSegment(value: 'income', label: Text('收入')), ButtonSegment(value: 'transfer', label: Text('转账'))],
            selected: {type},
            onSelectionChanged: (s) => setState(() => type = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
              controller: amount,
              focusNode: amountFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: theme.textTheme.headlineSmall,
              decoration: InputDecoration(labelText: '金额（$currency）', hintText: '0.00')),
          const SizedBox(height: 12),
          if (type != 'transfer') ...[
            // 分类用图标格子选，比下拉快
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in cats.where((c) => c.parentId == null))
                  ChoiceChip(
                    avatar: CategoryIcon(category: c, size: 22),
                    label: Text(c.name),
                    selected: categoryId == c.id,
                    onSelected: (_) => setState(() => categoryId = c.id),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          PickerField<String>(
            value: accountId,
            decoration: InputDecoration(labelText: type == 'transfer' ? '转出账户' : '账户'),
            items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.name))],
            onChanged: (v) => setState(() => accountId = v),
          ),
          if (type == 'transfer') ...[
            const SizedBox(height: 12),
            PickerField<String>(
              value: toAccountId,
              decoration: const InputDecoration(labelText: '转入账户'),
              items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => setState(() => toAccountId = v),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event, size: 18),
                  onPressed: () async {
                    final d = await showDatePicker(context: context, initialDate: when, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 1)));
                    if (d != null) setState(() => when = DateTime(d.year, d.month, d.day, when.hour, when.minute));
                  },
                  label: Text('${when.month}/${when.day}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule, size: 18),
                  onPressed: () async {
                    final tm = await showTimePicker(context: context, initialTime: TimeOfDay(hour: when.hour, minute: when.minute));
                    if (tm != null) setState(() => when = DateTime(when.year, when.month, when.day, tm.hour, tm.minute));
                  },
                  label: Text('${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(controller: desc, decoration: const InputDecoration(labelText: '说明（可选）', hintText: '午饭、打车…')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final Money m;
              try {
                m = Money.parse(amount.text.trim(), currency);
              } on FormatException {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('金额格式不对')));
                return;
              }
              if (m.minor <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('金额要大于 0')));
                return;
              }
              if (type != 'transfer' && categoryId == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('选一个分类')));
                return;
              }
              try {
                final t = app.addManual({
                  'type': type,
                  'amount_minor': m.minor,
                  'currency': currency,
                  'account_id': accountId,
                  if (type == 'transfer') 'to_account_id': toAccountId,
                  if (type != 'transfer') 'category_id': categoryId,
                  'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
                  'occurred_at': OccurredAt.fromLocal(when).toIso8601String(),
                });
                Navigator.pop(context, t);
              } on LedgerException catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
              }
            },
            child: const Text('记上'),
          ),
        ],
      ),
    );
  }
}
