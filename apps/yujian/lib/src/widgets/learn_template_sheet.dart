import 'package:flutter/material.dart';
import 'package:notification_templates/notification_templates.dart';

import '../app_state.dart';
import '../widgets/disclosure_tile.dart';
import '../widgets/fmt.dart';
import '../errors_zh.dart';

/// 通知来源 App 的显示名：内置名单认得的给中文名，认不得的给包名最后一段，没包名就是「任意 App」。
String noticeAppName(String? pkg) {
  if (pkg == null || pkg.isEmpty) return '任意 App';
  return packageAccountHints[pkg] ?? shoppingPackages[pkg] ?? pkg.split('.').last;
}

/// 「从最近的通知里选一条」：列出最近收到的原始通知，没认出来的排前面并标出来。
Future<RecentNotice?> pickRecentNotice(BuildContext context) {
  final app = AppScope.of(context);
  final list = [...app.recentNotices]..sort((a, b) => (a.usable ? 1 : 0) - (b.usable ? 1 : 0));
  return showModalBottomSheet<RecentNotice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  child: Text('还没收到过通知。打开「通知自动记账」并等一笔支付通知进来，或者直接粘贴通知文字。', style: theme.textTheme.bodyMedium),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                  children: [
                    for (final n in list)
                      ListTile(
                        title: Text(n.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${noticeAppName(n.packageName)} · ${fmtRelativeMs(n.postedAtMs)} · ${n.usable ? '已认出' : '没认出'}', style: theme.textTheme.bodySmall),
                        leading: Icon(n.usable ? Icons.check_circle_outline : Icons.help_outline, color: n.usable ? theme.colorScheme.primary : theme.colorScheme.error),
                        onTap: () => Navigator.pop(ctx, n),
                      ),
                  ],
                ),
        ),
      );
    },
  );
}

/// 「教它认一种通知」：用户看到的只有例子文案、点一下金额、选方向；正则由 TemplateLearner 生成。
/// [edit] 传已有模板则是改（同 id 覆盖）。返回 true = 已保存。
Future<bool> showLearnTemplateSheet(BuildContext context, {RecentNotice? from, Map<String, Object?>? edit}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _LearnSheet(from: from, edit: edit),
  );
  return r == true;
}

class _LearnSheet extends StatefulWidget {
  final RecentNotice? from;
  final Map<String, Object?>? edit;
  const _LearnSheet({this.from, this.edit});
  @override
  State<_LearnSheet> createState() => _LearnSheetState();
}

class _LearnSheetState extends State<_LearnSheet> {
  late final TextEditingController _text;
  late final TextEditingController _merchant;
  late final TextEditingController _account;
  late final TextEditingController _package;
  late final TextEditingController _regex;
  String? _pkg;
  String _direction = 'expense';
  int? _amountIndex;
  var _advancedTouched = false; // 高级区手改过正则后，自动生成不再覆盖
  List<AmountCandidate> _cands = const [];
  Map<String, Object?>? _tmpl; // 当前生成 / 手改出的模板
  String? _problem; // 学不出来的原因
  Extraction? _preview;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    final f = widget.from;
    _pkg = e != null ? ((e['packages'] as List?)?.cast<String>().firstOrNull) : f?.packageName;
    _text = TextEditingController(text: e != null ? (e['sample'] as String? ?? '') : (f?.text ?? ''));
    _merchant = TextEditingController();
    _account = TextEditingController(text: e != null ? (e['account_hint'] as String? ?? '') : (packageAccountHints[_pkg] ?? ''));
    _package = TextEditingController(text: _pkg ?? '');
    _regex = TextEditingController(text: e != null ? (e['text_re'] as String? ?? '') : '');
    _direction = (e?['direction'] as String?) ?? TemplateLearner.guessDirection(_text.text) ?? 'expense';
    if (e != null && _regex.text.isNotEmpty) _advancedTouched = true;
    _recompute(fromText: true, rebuild: false); // initState 里不能 setState
  }

  @override
  void dispose() {
    for (final c in [_text, _merchant, _account, _package, _regex]) {
      c.dispose();
    }
    super.dispose();
  }

  void _recompute({bool fromText = false, bool rebuild = true}) {
    final text = _text.text;
    if (fromText) {
      _cands = TemplateLearner.candidates(text);
      final likely = _cands.indexWhere((c) => c.likely);
      _amountIndex = _cands.isEmpty ? null : (likely >= 0 ? likely : 0);
      if (_merchant.text.isEmpty && text.isNotEmpty) {
        // 预填商户：拿内置启发式猜一个，用户不认可就清掉
        final x = TemplateMatcher().extract(NotificationEvent(packageName: _pkg ?? '', text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch));
        if (x.merchant != null && text.contains(x.merchant!)) _merchant.text = x.merchant!;
      }
    }
    final pkg = _package.text.trim().isEmpty ? null : _package.text.trim();
    final id = widget.edit?['id'] as String? ?? '${noticeAppName(pkg)} · 学 ${DateTime.now().millisecondsSinceEpoch % 100000}';
    Map<String, Object?>? t;
    if (_advancedTouched && _regex.text.trim().isNotEmpty) {
      t = {
        'id': id,
        'packages': pkg == null ? <String>[] : [pkg],
        'text_re': _regex.text.trim(),
        'direction': _direction,
        if (_account.text.trim().isNotEmpty) 'account_hint': _account.text.trim(),
        'confidence': 0.9,
        'sample': text,
      };
      _problem = null;
      try {
        RegExp(_regex.text.trim());
        if (!_regex.text.contains('(?<amount>')) _problem = '正则里要有 (?<amount>…) 分组';
      } on FormatException catch (e) {
        _problem = '正则不合法：${e.message}';
        t = null;
      }
    } else if (_amountIndex == null || text.trim().isEmpty) {
      t = null;
      _problem = text.trim().isEmpty ? '先把通知文字贴进来' : '文案里没有像金额的数字';
    } else {
      t = TemplateLearner.learn(id: id, packageName: pkg, text: text, amount: _cands[_amountIndex!], direction: _direction, merchant: _merchant.text, accountHint: _account.text);
      _problem = t == null ? '金额前后没有可以认的字，换一条通知试试' : null;
      if (t != null && !_advancedTouched) _regex.text = t['text_re'] as String;
    }
    _tmpl = t;
    _preview = null;
    if (t != null && _problem == null) {
      try {
        final m = TemplateMatcher(userTemplates: [NotificationTemplate.fromJson(t)]);
        _preview = m.extract(NotificationEvent(packageName: pkg ?? '', text: text, postedAtMs: DateTime.now().millisecondsSinceEpoch));
        if (_preview!.templateId == 'ignore') {
          _problem = '这条通知会被判成营销 / 验证码，直接忽略，模板不生效';
        } else if (_preview!.templateId != id) {
          _problem = '生成的模板没匹配上这条文案';
        }
      } catch (e) {
        _problem = '模板不合法：${friendlyError(e)}';
      }
    }
    if (rebuild) setState(() {});
  }

  Future<void> _save() async {
    final t = _tmpl;
    if (t == null || _problem != null) return;
    final app = AppScope.of(context);
    final s = app.settings;
    await app.saveSettings(s.copyWith(userTemplates: [...s.userTemplates.where((x) => x['id'] != t['id']), t]));
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _preview;
    final ok = _tmpl != null && _problem == null && p != null && p.usable;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(widget.edit != null ? '改这条模板' : '教它认一种通知', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('把一条通知当例子：点一下哪个数字是金额、选个方向，以后同样格式的通知就能自动记。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Row(children: [
            Icon(Icons.apps_outlined, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('来自：${noticeAppName(_package.text.trim().isEmpty ? null : _package.text.trim())}', style: theme.textTheme.bodyMedium),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '通知文字（例子）', hintText: '例：您尾号8888的卡消费36.50元，商户：肯德基'),
            onChanged: (_) => _recompute(fromText: true),
          ),
          const SizedBox(height: 16),
          Text('哪个数字是金额？', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (_cands.isEmpty)
            Text('文案里没找到数字', style: theme.textTheme.bodySmall)
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (var i = 0; i < _cands.length; i++)
                  ChoiceChip(
                    label: Text(_cands[i].text),
                    selected: _amountIndex == i,
                    onSelected: (_) {
                      _amountIndex = i;
                      _recompute();
                    },
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Text('这是一笔', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('支出')),
              ButtonSegment(value: 'income', label: Text('收入')),
              ButtonSegment(value: 'refund', label: Text('退款')),
              ButtonSegment(value: 'transfer', label: Text('转账')),
            ],
            selected: {_direction},
            onSelectionChanged: (v) {
              _direction = v.first;
              _recompute();
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _merchant,
            decoration: const InputDecoration(labelText: '商户（可不填）', helperText: '照抄文案里的那几个字，以后会自动认出同位置的商户名'),
            onChanged: (_) => _recompute(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _account,
            decoration: const InputDecoration(labelText: '记到哪个账户（可不填）', hintText: '招行 / 微信 / 支付宝'),
            onChanged: (_) => _recompute(),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: (ok ? theme.colorScheme.primary : theme.colorScheme.error).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? theme.colorScheme.primary : theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _problem ??
                      (p == null || !p.usable
                          ? '还认不出来'
                          : '会记成：${p.direction == 'income' ? '收入' : p.direction == 'transfer' ? '转账' : p.direction == 'refund' ? '退款' : '支出'} ${fmtMoney(p.amountMinor!, p.currency)}'
                              '${p.merchant != null ? ' · ${p.merchant}' : ''}${p.accountHint != null ? ' · ${p.accountHint}' : ''}'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          DisclosureTile(
            title: Text('高级：手改规则', style: theme.textTheme.bodyMedium),
            subtitle: Text('一般不用碰。这里是上面自动生成的内容', style: theme.textTheme.bodySmall),
            children: [
              TextField(
                controller: _package,
                decoration: const InputDecoration(labelText: '包名（留空 = 任意 App）', hintText: 'com.tencent.mm'),
                onChanged: (_) => _recompute(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _regex,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(labelText: '正文正则', helperText: '必须含 (?<amount>…) 分组；可选 (?<merchant>…)'),
                onChanged: (_) {
                  _advancedTouched = true;
                  _recompute();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: ok ? _save : null, child: Text(widget.edit != null ? '保存修改' : '保存，以后这样的通知都自动记')),
        ],
      ),
    );
  }
}
