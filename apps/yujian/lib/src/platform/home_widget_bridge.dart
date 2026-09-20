import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面小部件的数据推送（Android）。别的平台是空操作。
class HomeWidgetBridge {
  static const _m = MethodChannel('yujian/widget');

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 只在 Android 上给实例，别的平台 null。
  static HomeWidgetBridge? ifSupported() => supported ? HomeWidgetBridge() : null;

  /// [calYm] 是 `yyyy-MM`，[calExp] / [calInc] 是该月每天的支出 / 收入（分），逗号分隔、按日序；4×4 日历小部件用。
  /// [title] 是财富称号（贫困户 / 月光族 / …），空字符串 = 没有（没数据或游戏层关着），小部件上的胶囊就不显示。
  /// [disposable] 是「可花的」，[goals] 是 4×2 目标小部件用的 JSON 数组（最多 3 条，见 AppState.pushHomeWidget）。
  Future<void> update({required String balance, required String expense, required String income, required String month, String recent = '', String today = '', String calYm = '', String calExp = '', String calInc = '', String title = '', String disposable = '', String goals = '', String net = ''}) async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('update', {'balance': balance, 'expense': expense, 'income': income, 'month': month, 'recent': recent, 'today': today, 'cal_ym': calYm, 'cal_exp': calExp, 'cal_inc': calInc, 'title': title, 'disposable': disposable, 'goals': goals, 'net': net});
    } on PlatformException {
      // 没装小部件或系统不给，都不影响 App
    }
  }

  /// 桌面是否支持从 App 内直接添加小部件（Android 8+ 且桌面实现了 pin；不支持就只能长按桌面手动加）。
  Future<bool> pinSupported() async {
    if (!supported) return false;
    try {
      return await _m.invokeMethod<bool>('pinSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 弹系统的「添加到主屏幕」确认框。返回 false = 桌面不支持 / 系统拒绝。
  Future<bool> pin(String kind) async {
    if (!supported) return false;
    try {
      return await _m.invokeMethod<bool>('pin', {'kind': kind}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
