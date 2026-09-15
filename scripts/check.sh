#!/usr/bin/env bash
# 本机/CI 通用：分析 + 全部纯 Dart 测试 + 语料回归（rule）。不需要 Flutter。
set -euo pipefail
cd "$(dirname "$0")/.."
for p in ledger_core providers query_dsl interpreter persona notification_templates mcp_server sync_client; do
  (cd "packages/$p" && dart pub get --offline >/dev/null 2>&1 || dart pub get >/dev/null)
done
for p in ledger_core providers query_dsl interpreter persona notification_templates mcp_server sync_client; do
  echo "== $p"
  (cd "packages/$p" && dart analyze --fatal-infos && dart test --reporter expanded | tail -1)
done
echo "== corpus (rule)"
(cd packages/interpreter && dart run bin/corpus_eval.dart --mode rule --corpus ../../corpus/cases.json | tail -2)
