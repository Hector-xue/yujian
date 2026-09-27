/// 同步客户端（§12.3）。本地优先：先推本机待推变更，再拉其他设备的变更逐条应用（LWW）。
library;

export 'src/backup_crypto.dart';
export 'src/client.dart';
export 'src/sync_crypto.dart';
