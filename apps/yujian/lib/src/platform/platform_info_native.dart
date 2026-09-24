import 'dart:io';

/// 系统名（android / ios / windows / linux / macos）。
String platformName() => Platform.operatingSystem;

/// 反馈附带的「系统」一栏：系统名 + 版本（如 android 14 / Linux 5.14…），截短到 60 字。
String platformDescription() {
  final v = Platform.operatingSystemVersion;
  final s = '${Platform.operatingSystem} $v';
  return s.length > 60 ? s.substring(0, 60) : s;
}
