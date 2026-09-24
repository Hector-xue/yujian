#!/usr/bin/env bash
# 推之前在本机跑一遍：纯 Dart 包的 analyze + test + 版本号一致性。
# 本机没有 Flutter，所以 flutter analyze / widget 测试只能在 CI 上跑——但纯 Dart 包（账本、Provider、
# 解析器、本地模型…）占了大半代码量，先在本机挡掉低级错误，就不用为一个拼写错误烧一轮 CI。
set -euo pipefail
cd "$(dirname "$0")/.."
pkgs=(ledger_core providers query_dsl interpreter persona notification_templates mcp_server sync_client local_llm)
fail=0
for p in "${pkgs[@]}"; do
  [ -d "packages/$p" ] || continue
  printf '== %-24s' "$p"
  out=$( (cd "packages/$p" && dart pub get --offline >/dev/null 2>&1 || dart pub get >/dev/null 2>&1; dart analyze --fatal-infos 2>&1 && dart test --reporter failures-only 2>&1) ) && echo "ok" || { echo "FAIL"; echo "$out" | tail -20; fail=1; }
done
printf '== %-24s' "版本号"
scripts/check_version.sh >/dev/null && echo "ok" || { echo "FAIL"; fail=1; }
# 改过的 Dart 文件格式是否统一（CI 的 flutter analyze 不查格式，但仓库里都是 dart format 过的）
changed=$(git diff --name-only HEAD -- '*.dart'; git diff --cached --name-only HEAD -- '*.dart')
if [ -n "$changed" ]; then
  printf '== %-24s' "改动文件格式"
  # shellcheck disable=SC2086
  if dart format -o none $(echo "$changed" | sort -u | tr '\n' ' ') 2>/dev/null | grep -q "^Changed"; then
    echo "有文件没 format（dart format 一下）"; fail=1
  else
    echo "ok"
  fi
fi
[ "$fail" = 0 ] && echo "本机自检通过，可以推" || { echo "本机自检没过，别推"; exit 1; }
