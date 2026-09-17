import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 陪聊层攒下的、关于用户本人的事（称呼、习惯、家人宠物、目标……）。
/// 只存本机；用户在「模型与人格」里能看、能删。不碰账本。
class MemoryItem {
  final String text;
  final int atMs;
  const MemoryItem(this.text, this.atMs);
  Map<String, Object?> toJson() => {'text': text, 'at': atMs};
  static MemoryItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['text'];
    if (t is! String || t.trim().isEmpty) return null;
    return MemoryItem(t.trim(), (j['at'] as num?)?.toInt() ?? 0);
  }
}

class CompanionMemory {
  static const _key = 'companion_memory_v1';
  static const max = 60;
  final List<MemoryItem> items = [];
  var _loaded = false;

  List<String> get lines => items.map((m) => m.text).toList();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      items
        ..clear()
        ..addAll((jsonDecode(raw) as List).map(MemoryItem.fromJson).whereType<MemoryItem>());
    } catch (_) {
      // 坏了就从空开始
    }
  }

  /// 去重（同一句不重复记），超过上限丢最旧的。返回真正新增的那几条。
  Future<List<String>> addAll(Iterable<String> facts) async {
    final added = <String>[];
    for (final f in facts) {
      final t = f.trim();
      if (t.isEmpty || items.any((m) => m.text == t)) continue;
      items.add(MemoryItem(t, DateTime.now().millisecondsSinceEpoch));
      added.add(t);
    }
    while (items.length > max) {
      items.removeAt(0);
    }
    if (added.isNotEmpty) await _save();
    return added;
  }

  Future<void> remove(String text) async {
    items.removeWhere((m) => m.text == text);
    await _save();
  }

  Future<void> clear() async {
    items.clear();
    await _save();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(items.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }
}
