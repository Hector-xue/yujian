/// 系统信息（反馈附带用）：原生走 dart:io，Web 只报 web。
library;

export 'platform_info_native.dart' if (dart.library.js_interop) 'platform_info_web.dart';
