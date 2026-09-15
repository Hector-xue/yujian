/// 模型 Provider 层。只做一件事：把 (system, user) 变成文本或 JSON；能力按模型实测，不按厂商猜。
library;

export 'src/capability_probe.dart';
export 'src/config.dart';
export 'src/openai_compat.dart';
export 'src/provider.dart';
