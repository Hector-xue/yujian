/// 余见 Yujian 账本核心。纯逻辑、零 UI、零网络。
///
/// 写路径唯一：`Ledger.propose` → 收件箱 → `Ledger.commit`。
library;

export 'src/achievements.dart';
export 'src/benchmark.dart';
export 'src/budget.dart';
export 'src/checkup.dart';
export 'src/cards.dart';
export 'src/changes.dart';
export 'src/debts.dart';
export 'src/goals.dart';
export 'src/db/database.dart';
export 'src/errors.dart';
export 'src/ids.dart';
export 'src/ledger.dart';
export 'src/memory.dart';
export 'src/models/account.dart';
export 'src/models/audit.dart';
export 'src/models/category.dart';
export 'src/models/draft.dart';
export 'src/models/enums.dart';
export 'src/models/transaction.dart';
export 'src/money.dart';
export 'src/occurred_at.dart';
export 'src/plan.dart';
export 'src/portability.dart';
export 'src/profile.dart';
export 'src/recurring.dart';
export 'src/tasks.dart';
export 'src/validation.dart' show Analysis, ValidatedTransaction, analyzeCreatePayload;
export 'src/wealth.dart';
