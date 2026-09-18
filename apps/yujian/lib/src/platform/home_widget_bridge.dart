import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面小部件的数据推送（Android）。别的平台是空操作。
class HomeWidgetBridge {
  static const _m = MethodChannel('yujian/widget');

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 只在 Android 上给实例，别的平台 null。
  static HomeWidgetBridge? ifSupported() => supported ? HomeWidgetBridge() : null;

  /// [calYm] 是 `yyyy-MM`，[calExp] / [calInc] 是该月每天的支出 / 收入（分），逗号分隔、按日序；4×4 日历小部件用。
  Future<void> update({required String balance, required String expense, required String income, required String month, String recent = '', String today = '', String calYm = '', String calExp = '', String calInc = ''}) async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('update', {'balance': balance, 'expense': expense, 'income': income, 'month': month, 'recent': recent, 'today': today, 'cal_ym': calYm, 'cal_exp': calExp, 'cal_inc': calInc});
    } on PlatformException {
      // 没装小部件或系统不给，都不影响 App
    }
  }
}
