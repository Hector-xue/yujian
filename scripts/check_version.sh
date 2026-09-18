#!/usr/bin/env bash
# 版本号三处必须一致：apps/yujian/pubspec.yaml 的 version、lib/src/version.dart 的 appVersion、（发版时）tag。
# 0.8.3 发版时 version.dart 忘了改，装上的 App 自认 0.8.2，每次启动都弹"有新版本 0.8.3"——这个脚本在 CI 里堵住它。
set -euo pipefail
cd "$(dirname "$0")/../apps/yujian"
pub=$(awk '/^version:/{print $2; exit}' pubspec.yaml | cut -d+ -f1)
dart=$(sed -n "s/^const appVersion = '\([^']*\)';/\1/p" lib/src/version.dart)
[ -n "$pub" ] && [ -n "$dart" ] || { echo "读不到版本号：pubspec=$pub version.dart=$dart"; exit 1; }
[ "$pub" = "$dart" ] || { echo "版本不一致：pubspec.yaml=$pub，lib/src/version.dart=$dart"; exit 1; }
if [ -n "${1:-}" ]; then
  tag="${1#v}"
  [ "$tag" = "$pub" ] || { echo "tag v$tag 和 pubspec.yaml=$pub 不一致"; exit 1; }
fi
echo "版本一致：$pub${1:+（tag $1）}"
