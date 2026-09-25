import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../version.dart';
import 'update_io_native.dart' if (dart.library.js_interop) 'update_io_web.dart' as io;

/// 门户上的最新版信息（yujian.ivyea.com/download/version.json，由发版同步脚本生成）。
/// 顶层 *_url 是主线路（GitHub Release）；[mirror] 是同名键的备用线路，主线路下不动时用。
class ReleaseInfo {
  final String version;
  final String notes;
  final String? androidArm64;
  final String? androidArm32;
  final String? windows;
  final String? linux;
  final String? web;
  final String page;
  final Map<String, String> mirror;
  const ReleaseInfo({required this.version, required this.notes, this.androidArm64, this.androidArm32, this.windows, this.linux, this.web, required this.page, this.mirror = const {}});

  factory ReleaseInfo.fromJson(Map<String, Object?> j) => ReleaseInfo(
        version: j['version'] as String,
        notes: (j['notes'] as String?) ?? '',
        androidArm64: j['android_arm64_url'] as String?,
        androidArm32: j['android_arm32_url'] as String?,
        windows: j['windows_url'] as String?,
        linux: j['linux_url'] as String?,
        web: j['web_url'] as String?,
        page: (j['page'] as String?) ?? 'https://yujian.ivyea.com/',
        mirror: {
          for (final e in ((j['mirror'] as Map?) ?? const {}).entries)
            if (e.value is String && (e.value as String).isNotEmpty) e.key as String: e.value as String,
        },
      );

  bool get isNewer => compareVersions(version, appVersion) > 0;

  /// 当前平台该下哪个包；null = 这个平台没有直装包（比如 Web / macOS）。
  String? get downloadForThisPlatform {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => androidArm64,
      TargetPlatform.windows => windows,
      TargetPlatform.linux => linux,
      _ => null,
    };
  }

  /// 当前平台直装包的备用线路；null = 没有备用。
  String? get mirrorForThisPlatform {
    if (kIsWeb) return null;
    final key = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android_arm64_url',
      TargetPlatform.windows => 'windows_url',
      TargetPlatform.linux => 'linux_url',
      _ => null,
    };
    final m = key == null ? null : mirror[key];
    return m == downloadForThisPlatform ? null : m;
  }

  /// App 内安装包的下载顺序：主线路在前，备用在后（去重去空）。
  List<String> get androidSources => {?androidArm64, ?mirror['android_arm64_url']}.toList();
}

/// "0.4.1" vs "0.10.0" 按段比较；带后缀（-beta）的段按数字前缀算。
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.replaceFirst(RegExp(r'^v'), '').split('.').map((p) => int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

class Updater {
  static const endpoint = 'https://yujian.ivyea.com/download/version.json';

  static Future<ReleaseInfo?> check({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse('$endpoint?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}')).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return ReleaseInfo.fromJson((jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  static bool get canInstallInApp => io.canInstallInApp && io.isAndroid;

  /// Android：按 [ReleaseInfo.androidSources] 顺序下载 apk 到缓存，一条线路失败、卡住或被用户喊换，就换下一条；下完拉起系统安装器。
  /// [attempt] 包住每一次下载（出网记录按实际线路记）；[onSwitch] 在换线路前告诉界面；[skip] 返回 true = 用户嫌慢，放弃当前线路。
  static Future<void> downloadAndInstall(
    ReleaseInfo r,
    void Function(double) onProgress, {
    Future<String> Function(String url, Future<String> Function() go)? attempt,
    void Function(String url, Object error)? onSwitch,
    bool Function()? skip,
  }) async {
    final sources = r.androidSources;
    if (sources.isEmpty) throw Exception('这个版本没有 Android 包');
    String? path;
    Object? last;
    for (var i = 0; i < sources.length && path == null; i++) {
      final url = sources[i];
      Future<String> go() => io.downloadTo(url, 'yujian-${r.version}.apk', onProgress, cancelled: skip);
      try {
        path = await (attempt == null ? go() : attempt(url, go));
      } catch (e) {
        last = e;
        if (i + 1 < sources.length) {
          onProgress(0);
          onSwitch?.call(sources[i + 1], e);
        }
      }
    }
    if (path == null) throw last!;
    await io.installApk(path);
  }
}
