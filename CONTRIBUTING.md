# 贡献指南

- 账本规则改动必须带测试；`packages/ledger_core` 是唯一的事实实现，不要在别处复制账本逻辑。
- 任何写账本的入口都必须经 `propose → commit`，PR 里出现绕过草稿的直写会被拒。
- 金额只用整数最小单位；时间必须带偏移。
- 提交前：`dart analyze` 零告警，`dart test` 全绿。
