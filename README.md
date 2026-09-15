# 余见 Yujian

开源、本地优先、自选模型、人格可定制的个人财务 Agent。

> 账本事实在你的设备上，AI 只负责理解和解释，写入永远经你确认。

## 原则

- **AI 负责理解，账本核心负责事实，用户负责授权。** 模型只能提议（`propose`），提交（`commit`）由用户在收件箱完成。
- **Local-first。** 账本核心是一个纯 Dart 包，随 App 运行；服务端是可选外围（同步 / 备份 / MCP）。
- **BYOM。** OpenAI-compatible、Anthropic、Ollama、Gemini，能力按模型实测，不按厂商猜。
- **人格只改语气。** 触不到金额、时间、余额、权限与确认流程。

## 仓库结构

```
packages/ledger_core   账本核心：账户 / 交易 + posting 轻复式 / 草稿收件箱 / 审计 / 完整性校验
packages/interpreter   自然语言 → 草稿（规则优先，LLM 兜底）        [Sprint 2]
packages/query_dsl     查询 DSL（模型只出 JSON，引擎执行）          [Sprint 2]
packages/providers     模型 Provider 抽象与能力探测                 [Sprint 2]
apps/yujian            Flutter App                                  [Phase 1]
server/                可选 Python 服务端                            [Phase 3]
corpus/                解析语料
personas/              人格包
```

## 开发

需要 Dart SDK ≥ 3.6（Phase 0 不需要 Flutter）。

```bash
dart pub get
dart analyze
dart test packages/ledger_core
```

## 账本核心速览

```dart
final db = LedgerDatabase.open('yujian.db');
final ledger = Ledger(db)..seedDefaultCategories();
final wechat = ledger.createAccount(name: '微信', type: AccountType.eWallet, currency: 'CNY');

// 模型 / 规则 / 通知只能走这里
final drafts = ledger.propose([
  DraftInput(payload: {
    'type': 'expense', 'amount_minor': 2800, 'currency': 'CNY',
    'account_id': wechat.id, 'category_id': 'food',
    'occurred_at': '2026-09-15T12:30:00+08:00', 'description': '午餐',
  }),
], source: Source.chat, interpreter: 'hybrid', modelUsed: 'deepseek-chat');

// 用户在收件箱确认；幂等，可带修改
final tx = ledger.commit(drafts.single.id, edits: {'category_id': 'transport'});
ledger.balance(wechat.id);      // 由流水推导，不落库
ledger.auditFor(tx.id);         // propose → commit → create 全链
```

金额一律最小货币单位整数；时间带偏移存储；交易由 type 决定 posting 结构（expense 一负、income 一正、transfer 一负一正和为零、refund 挂原交易且不超余额、adjustment 必填原因）。

## 许可证

MIT
