import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../feedback/feedback_store.dart';
import '../platform/platform_info.dart';
import '../theme.dart';
import '../version.dart';
import 'feedback_history_page.dart';

/// 反馈的接收端（yujian.ivyea.com 上的 yujian-feedback 服务：落盘 + 转作者的飞书）。
const feedbackEndpoint = 'https://yujian.ivyea.com/api/feedback';

/// 反馈 BUG / 建议：文字 + 最多 4 张截图 + 可选联系方式；附带信息（版本 / 系统 / 屏幕 / 主题）明着列出来、可以不带。
/// 只在点「发送」时出网，记进出网记录；纯本地模式下不能发。
/// 写到一半返回 / App 被杀，草稿都在（[FeedbackStore]）；发出去的记进本机历史，右上角能翻。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});
  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  static const maxImages = 4;
  static const maxImageBytes = 2 * 1024 * 1024;
  final _text = TextEditingController();
  final _contact = TextEditingController();
  final _images = <Uint8List>[];
  var _kind = 'bug';
  var _withInfo = true;
  var _sending = false;
  var _touched = false; // 草稿从磁盘读回来之前用户已经动过了，就别拿旧草稿盖掉
  var _historyCount = 0;

  @override
  void initState() {
    super.initState();
    final cached = FeedbackStore.cached;
    if (cached != null) {
      _apply(cached);
    } else {
      FeedbackStore.loadDraft().then((d) {
        if (mounted && !_touched) setState(() => _apply(d));
      });
    }
    _text.addListener(_onEdit);
    _contact.addListener(_onEdit);
    _loadHistoryCount();
  }

  Future<void> _loadHistoryCount() async {
    final n = (await FeedbackStore.history()).length;
    if (mounted) setState(() => _historyCount = n);
  }

  void _apply(FeedbackDraft d) {
    _kind = d.kind;
    _withInfo = d.withInfo;
    _images
      ..clear()
      ..addAll(d.images);
    _text.text = d.text;
    _contact.text = d.contact;
  }

  void _onEdit() {
    _touched = true;
    _save();
  }

  void _save({bool imagesChanged = false}) {
    _touched = true;
    FeedbackStore.saveDraft(
      FeedbackDraft(kind: _kind, text: _text.text, contact: _contact.text, withInfo: _withInfo, images: List.unmodifiable(_images)),
      imagesChanged: imagesChanged,
    );
  }

  @override
  void dispose() {
    FeedbackStore.flushDraft();
    _text.dispose();
    _contact.dispose();
    super.dispose();
  }

  /// 附带信息：用户在页面上看得见的就是会发的，一字不差。
  Map<String, String> _info(BuildContext context) {
    final mq = MediaQuery.of(context);
    final app = AppScope.of(context);
    return {
      '版本': appVersion,
      '系统': platformDescription(),
      '屏幕': '${mq.size.width.round()}×${mq.size.height.round()} @${mq.devicePixelRatio.toStringAsFixed(2)}x',
      '主题': app.settings.themeId,
    };
  }

  Future<void> _pick() async {
    final left = maxImages - _images.length;
    if (left <= 0) return;
    try {
      // 压到 1600 宽、质量 80：截图看得清字，一张通常几百 KB
      final files = await ImagePicker().pickMultiImage(maxWidth: 1600, maxHeight: 3200, imageQuality: 80, limit: left);
      var tooBig = 0;
      for (final f in files.take(left)) {
        final b = await f.readAsBytes();
        if (b.length > maxImageBytes) {
          tooBig++;
          continue;
        }
        _images.add(b);
      }
      if (!mounted) return;
      setState(() {});
      _save(imagesChanged: true);
      if (tooBig > 0) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$tooBig 张图压缩后还超过 2MB，没加上')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选图失败：$e')));
    }
  }

  Future<void> _send() async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final text = _text.text.trim();
    if (text.length < 2) {
      messenger.showSnackBar(const SnackBar(content: Text('写两句：发生了什么 / 想要什么')));
      return;
    }
    if (app.settings.offlineMode) {
      messenger.showSnackBar(const SnackBar(content: Text('纯本地模式开着，不能发反馈（更多 → 隐私 可关掉）')));
      return;
    }
    final info = _withInfo ? _info(context) : const <String, String>{};
    final body = jsonEncode({
      'kind': _kind,
      'text': text,
      'contact': _contact.text.trim(),
      'version': _withInfo ? appVersion : '',
      'platform': _withInfo ? platformName() : '',
      'device': info,
      'images': [for (final b in _images) base64Encode(b)],
    });
    setState(() => _sending = true);
    try {
      final total = _images.fold<int>(0, (a, b) => a + b.length);
      final id = await app.netLog.track(() async {
        final r = await http.post(Uri.parse(feedbackEndpoint), headers: {'Content-Type': 'application/json'}, body: body).timeout(const Duration(seconds: 60));
        Map<String, Object?> j;
        try {
          j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, Object?>();
        } catch (_) {
          throw Exception('服务器返回了看不懂的内容（HTTP ${r.statusCode}）');
        }
        if (r.statusCode != 200 || j['ok'] != true) throw Exception('${j['error'] ?? 'HTTP ${r.statusCode}'}');
        return '${j['id']}';
      }, kind: 'feedback', purpose: 'send', host: Uri.parse(feedbackEndpoint).host, chars: text.length, bytes: total, count: _images.length);
      final sent = List<Uint8List>.of(_images);
      await FeedbackStore.addHistory(
        FeedbackRecord(id: id, atMs: DateTime.now().millisecondsSinceEpoch, kind: _kind, text: text, contact: _contact.text.trim(), imageCount: sent.length),
        sent,
      );
      if (!mounted) return;
      setState(() {
        _text.clear();
        _images.clear();
        _historyCount++;
      });
      await FeedbackStore.clearDraft();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('收到了，谢谢'),
          content: Text('作者会看到这条反馈。编号 $id${_contact.text.trim().isEmpty ? '' : '，需要的话会按你留的方式联系你'}。'),
          actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('好'))],
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('没发出去：${'$e'.replaceFirst('Exception: ', '')}。写的内容还在，稍后再点发送')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final info = _info(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('反馈 BUG / 建议'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FeedbackHistoryPage()));
              _loadHistoryCount();
            },
            icon: const Icon(Icons.history, size: 20),
            label: Text(_historyCount > 0 ? '我发过的 $_historyCount' : '我发过的'),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'bug', label: Text('BUG')), ButtonSegment(value: 'idea', label: Text('建议')), ButtonSegment(value: 'other', label: Text('其他'))],
              selected: {_kind},
              onSelectionChanged: (v) {
                setState(() => _kind = v.first);
                _save();
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 5,
            maxLines: 12,
            maxLength: 4000,
            decoration: InputDecoration(
              labelText: _kind == 'bug' ? '发生了什么' : (_kind == 'idea' ? '想要什么' : '想说的'),
              hintText: _kind == 'bug' ? '在哪个页面、做了什么、看到了什么、本来应该是什么样' : (_kind == 'idea' ? '想要什么功能 / 哪里用着别扭' : ''),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 4),
          Text('截图（最多 $maxImages 张）', style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < _images.length; i++)
              Stack(children: [
                ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(_images[i], width: 76, height: 76, fit: BoxFit.cover, cacheWidth: 228)),
                Positioned(
                  top: 2,
                  right: 2,
                  child: InkWell(
                    onTap: () {
                      setState(() => _images.removeAt(i));
                      _save(imagesChanged: true);
                    },
                    child: Container(decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle), padding: const EdgeInsets.all(3), child: const Icon(Icons.close, size: 14, color: Color(0xFFFFFFFF))),
                  ),
                ),
              ]),
            if (_images.length < maxImages)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _pick,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: y.hairline, width: 1.2)),
                  child: Icon(Icons.add_photo_alternate_outlined, color: y.muted),
                ),
              ),
          ]),
          const SizedBox(height: 14),
          TextField(controller: _contact, decoration: const InputDecoration(labelText: '联系方式（可不填）', hintText: '微信 / 邮箱，需要追问时联系你')),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _withInfo,
            onChanged: (v) {
              setState(() => _withInfo = v ?? true);
              _save();
            },
            title: const Text('附带版本和机型信息'),
            subtitle: Text(info.entries.map((e) => '${e.key}：${e.value}').join('\n'), style: theme.textTheme.bodySmall),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _sending || app.settings.offlineMode ? null : _send,
            icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send, size: 18),
            label: Text(_sending ? '发送中…' : '发送'),
          ),
          const SizedBox(height: 10),
          Text(
            app.settings.offlineMode
                ? '纯本地模式开着：发不了反馈（更多 → 隐私 可以关掉）。'
                : '发到余见作者的服务器，存下后转到作者的飞书；截图不会放到任何公开链接。不带任何账本数据。这一次会记进「出网记录」。没发出去的内容自动存在本机，返回再进来还在。',
            style: theme.textTheme.bodySmall?.copyWith(color: y.muted),
          ),
          if (kDebugMode) Text(feedbackEndpoint, style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
        ],
      ),
    );
  }
}
