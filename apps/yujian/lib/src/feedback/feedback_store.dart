import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feedback_files_native.dart' if (dart.library.js_interop) 'feedback_files_web.dart' as files;

/// 没发出去的反馈：返回、切走、App 被杀后再进来都还在；发送成功才清掉。
class FeedbackDraft {
  final String kind;
  final String text;
  final String contact;
  final bool withInfo;
  final List<Uint8List> images;
  const FeedbackDraft({this.kind = 'bug', this.text = '', this.contact = '', this.withInfo = true, this.images = const []});

  bool get isEmpty => text.trim().isEmpty && contact.trim().isEmpty && images.isEmpty;

  Map<String, Object?> toJson() => {'kind': kind, 'text': text, 'contact': contact, 'with_info': withInfo};

  static FeedbackDraft fromJson(Map<String, Object?> j, List<Uint8List> images) => FeedbackDraft(
        kind: (j['kind'] as String?) ?? 'bug',
        text: (j['text'] as String?) ?? '',
        contact: (j['contact'] as String?) ?? '',
        withInfo: (j['with_info'] as bool?) ?? true,
        images: images,
      );
}

/// 发出去的一条反馈（只存在本机；服务器那头不回传任何东西）。
class FeedbackRecord {
  final String id; // 服务器给的编号
  final int atMs;
  final String kind;
  final String text;
  final String contact;
  final int imageCount;
  const FeedbackRecord({required this.id, required this.atMs, required this.kind, required this.text, this.contact = '', this.imageCount = 0});

  Map<String, Object?> toJson() => {'id': id, 'at': atMs, 'kind': kind, 'text': text, 'contact': contact, 'images': imageCount};

  static FeedbackRecord fromJson(Map<String, Object?> j) => FeedbackRecord(
        id: '${j['id']}',
        atMs: (j['at'] as num?)?.toInt() ?? 0,
        kind: (j['kind'] as String?) ?? 'other',
        text: (j['text'] as String?) ?? '',
        contact: (j['contact'] as String?) ?? '',
        imageCount: (j['images'] as num?)?.toInt() ?? 0,
      );

  static String kindName(String kind) => switch (kind) { 'bug' => 'BUG', 'idea' => '建议', _ => '其他' };
}

/// 反馈草稿与历史：文字进 SharedPreferences，截图进应用私有目录（Web 只在内存）。
class FeedbackStore {
  static const draftKey = 'feedback_draft';
  static const historyKey = 'feedback_history';
  static const draftDir = 'draft';
  static const historyCap = 50;

  /// 进程内的草稿：同一次打开 App 里来回进出反馈页直接用它，不用等磁盘，也不会先闪一下空页。
  static FeedbackDraft? _mem;
  static Timer? _debounce;

  static FeedbackDraft? get cached => _mem;

  /// 读草稿：先看内存，没有再读磁盘（App 刚启动）。
  static Future<FeedbackDraft> loadDraft() async {
    if (_mem != null) return _mem!;
    final raw = (await SharedPreferences.getInstance()).getString(draftKey);
    if (raw == null) return _mem = const FeedbackDraft();
    try {
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      return _mem = FeedbackDraft.fromJson(j, await files.readImages(draftDir));
    } catch (_) {
      return _mem = const FeedbackDraft();
    }
  }

  /// 存草稿：内存立刻更新；文字攒 400ms 再落盘（打字时不每个字都写），截图变了立刻写文件。
  static void saveDraft(FeedbackDraft d, {bool imagesChanged = false}) {
    _mem = d;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _writeDraft(d));
    if (imagesChanged) unawaited(files.writeImages(draftDir, d.images));
  }

  /// 离开页面时调用：把还在攒的那一下立刻写掉。
  static Future<void> flushDraft() async {
    final d = _mem;
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      if (d != null) await _writeDraft(d);
    }
  }

  static Future<void> _writeDraft(FeedbackDraft d) async {
    final p = await SharedPreferences.getInstance();
    if (d.isEmpty) {
      await p.remove(draftKey);
    } else {
      await p.setString(draftKey, jsonEncode(d.toJson()));
    }
  }

  static Future<void> clearDraft() async {
    _debounce?.cancel();
    _mem = const FeedbackDraft();
    await (await SharedPreferences.getInstance()).remove(draftKey);
    await files.removeImages(draftDir);
  }

  static Future<List<FeedbackRecord>> history() async {
    final raw = (await SharedPreferences.getInstance()).getString(historyKey);
    if (raw == null) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List) FeedbackRecord.fromJson((e as Map).cast<String, Object?>())];
    } catch (_) {
      return const [];
    }
  }

  /// 发送成功后记一条（新的在前），截图另存一份给历史页看；超过 [historyCap] 条把最老的连截图一起删掉。
  static Future<void> addHistory(FeedbackRecord r, List<Uint8List> images) async {
    final list = [r, ...(await history()).where((e) => e.id != r.id)];
    final keep = list.take(historyCap).toList();
    for (final gone in list.skip(historyCap)) {
      await files.removeImages('h_${gone.id}');
    }
    await (await SharedPreferences.getInstance()).setString(historyKey, jsonEncode([for (final e in keep) e.toJson()]));
    if (images.isNotEmpty) await files.writeImages('h_${r.id}', images);
  }

  static Future<void> removeHistory(String id) async {
    final keep = (await history()).where((e) => e.id != id).toList();
    await (await SharedPreferences.getInstance()).setString(historyKey, jsonEncode([for (final e in keep) e.toJson()]));
    await files.removeImages('h_$id');
  }

  static Future<List<Uint8List>> historyImages(String id) => files.readImages('h_$id');

  @visibleForTesting
  static void resetMemory() {
    _debounce?.cancel();
    _mem = null;
  }
}
