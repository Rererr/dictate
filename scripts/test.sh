#!/bin/zsh
# 共通核とアプリのテストを両方回す。
# Command Line Tools だけの環境では、swift test がテスト用マクロのプラグインを
# 見つけたり見つけなかったりする（同じコードで結果が変わる）。場所を明示すると安定する。
set -euo pipefail
cd "${0:A:h}/.."
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
for package in Packages/SpeechCore .; do
    swift test --package-path "$package" -Xswiftc -plugin-path -Xswiftc "$plugins"
done
