import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../feedback/feedback_store.dart';
import '../theme.dart';
import '../widgets/action_sheet.dart';
import '../widgets/fmt.dart';

/// 我发过的反馈：只存在本机（发送成功时记下），新的在前，最多 50 条。
/// 编号是服务器给的，找作者追问时报这个编号最快。
class FeedbackHistoryPage extends StatefulWidget {
  const FeedbackHistoryPage({super.key});
  @override
  State<FeedbackHistoryPage> createState() => _FeedbackHistoryPageState();
}

class _FeedbackHistoryPageState extends State<FeedbackHistoryPage> {
  List<FeedbackRecord>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await FeedbackStore.history();
    if (mounted) setState(() => _items = list);
  }

  Future<void> _more(FeedbackRecord r) async {
    final messenger = ScaffoldMessenger.of(context);
    final v = await showActionSheet<String>(context, title: '编号 ${r.id}', actions: const [
      SheetAction('copy', '复制编号', icon: Icons.copy),
      SheetAction('copy_text', '复制内容', icon: Icons.notes),
      SheetAction('delete', '从这台手机上删掉', icon: Icons.delete_outline, danger: true),
    ]);
    switch (v) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: r.id));
        messenger.showSnackBar(const SnackBar(content: Text('编号已复制')));
      case 'copy_text':
        await Clipboard.setData(ClipboardData(text: r.text));
        messenger.showSnackBar(const SnackBar(content: Text('内容已复制')));
      case 'delete':
        await FeedbackStore.removeHistory(r.id);
        await _load();
        messenger.showSnackBar(const SnackBar(content: Text('删掉了（只删本机的记录，作者那边已经收到）')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('我发过的反馈')),
      body: items == null
          ? const SizedBox.shrink()
          : items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('还没发过反馈。发送成功的每一条都会记在这里（只存在这台手机上）。', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: y.muted)),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + MediaQuery.paddingOf(context).bottom),
                  itemCount: items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == items.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Text('只存在这台手机上，最多留 ${FeedbackStore.historyCap} 条。找作者追问时报编号最快。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                      );
                    }
                    final r = items[i];
                    return GlassCard(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        onLongPress: () => _more(r),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 6, 14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(FeedbackRecord.kindName(r.kind), style: theme.textTheme.labelLarge?.copyWith(color: r.kind == 'bug' ? y.danger : theme.colorScheme.primary)),
                              const SizedBox(width: 8),
                              Expanded(child: Text('${fmtRelativeMs(r.atMs)} · 编号 ${r.id}', style: theme.textTheme.bodySmall?.copyWith(color: y.muted), overflow: TextOverflow.ellipsis)),
                              IconButton(onPressed: () => _more(r), icon: Icon(Icons.more_horiz, color: y.muted), visualDensity: VisualDensity.compact, tooltip: '更多'),
                            ]),
                            Padding(padding: const EdgeInsets.only(right: 10), child: Text(r.text, style: theme.textTheme.bodyMedium)),
                            if (r.contact.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('联系方式：${r.contact}', style: theme.textTheme.bodySmall?.copyWith(color: y.muted))),
                            if (r.imageCount > 0) _Shots(id: r.id, count: r.imageCount),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// 这条反馈带的截图：本机有存就显示缩略图，点开看大图；Web / 存图失败时只写张数。
class _Shots extends StatefulWidget {
  final String id;
  final int count;
  const _Shots({required this.id, required this.count});
  @override
  State<_Shots> createState() => _ShotsState();
}

class _ShotsState extends State<_Shots> {
  late final Future<List<Uint8List>> _images = FeedbackStore.historyImages(widget.id);

  void _open(Uint8List b) {
    showDialog<void>(
      context: context,
      builder: (d) => GestureDetector(
        onTap: () => Navigator.pop(d),
        child: InteractiveViewer(child: Center(child: Image.memory(b))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 10),
      child: FutureBuilder<List<Uint8List>>(
        future: _images,
        builder: (context, snap) {
          final imgs = snap.data ?? const <Uint8List>[];
          if (imgs.isEmpty) {
            return Text(snap.connectionState == ConnectionState.done ? '带了 ${widget.count} 张截图' : '', style: theme.textTheme.bodySmall?.copyWith(color: y.muted));
          }
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in imgs)
              GestureDetector(
                onTap: () => _open(b),
                child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(b, width: 64, height: 64, fit: BoxFit.cover, cacheWidth: 192)),
              ),
          ]);
        },
      ),
    );
  }
}
