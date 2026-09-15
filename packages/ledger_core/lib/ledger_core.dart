/// 余见 Yujian 账本核心。纯逻辑、零 UI、零网络。
///
/// 写路径唯一：`Ledger.propose` → 收件箱 → `Ledger.commit`。
library;

export 'src/db/database.dart';
export 'src/errors.dart';
export 'src/ids.dart';
export 'src/ledger.dart';
export 'src/models/account.dart';
export 'src/models/audit.dart';
export 'src/models/category.dart';
export 'src/models/draft.dart';
export 'src/models/enums.dart';
export 'src/models/transaction.dart';
export 'src/money.dart';
export 'src/occurred_at.dart';
export 'src/validation.dart' show Analysis, ValidatedTransaction, analyzeCreatePayload;
