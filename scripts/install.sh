#!/bin/zsh
# 前提を確かめ、組んで、~/Applications/Dictate.app に置いて、起動する。
# 使い方: scripts/install.sh            前提の確認、ビルド、配置、起動
#         scripts/install.sh --uninstall  ~/Applications/Dictate.app を消す（設定と履歴は残す）
set -euo pipefail
cd "${0:A:h}/.."
app=~/Applications/Dictate.app
fail() { print -u2 "install.sh: $1"; exit 1 }

if [[ "${1:-}" == --uninstall ]]; then
    pkill -x Dictate 2>/dev/null || true
    rm -rf "$app"
    print "消しました: $app"
    print "設定と履歴は残しています: ~/Library/Application Support/Dictate/"
    print "許可の記録も消すなら: tccutil reset Accessibility com.rererr.dictate"
    exit 0
fi

[[ "$(uname -m)" == arm64 ]] || fail "Apple Silicon の Mac が必要です（この Mac: $(uname -m)）"
os="$(sw_vers -productVersion)"
(( ${os%%.*} >= 26 )) || fail "macOS 26 以降が必要です（この Mac: $os）"
xcode-select -p >/dev/null 2>&1 || fail "Command Line Tools がありません。xcode-select --install を実行し、終わってからもう一度流してください"
swift_output="$(swift --version 2>&1)" || fail "swift が動きません。xcode-select --install で Command Line Tools を入れ直してください。swift の出力: $swift_output"
swift_version="$(print -r -- "$swift_output" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
[[ -n "$swift_version" ]] || fail "swift の版を読めません。出力: $swift_output"
autoload -U is-at-least
is-at-least 6.2 "$swift_version" || fail "Swift 6.2 以降が必要です（この Mac: $swift_version）。Command Line Tools を更新してください"

scripts/bundle.sh
# 終了を待ってから起動する。前のプロセスがホットキーを握ったままだと、新しい方の登録が失敗する
pkill -x Dictate 2>/dev/null || true
for _ in {1..30}; do
    pgrep -x Dictate >/dev/null || break
    sleep 0.1
done
mkdir -p ~/Applications
rm -rf "$app"
ditto build/Dictate.app "$app"
print "置きました: $app"
# 前のプロセスの終了直後は LaunchServices が -600 で open を拒むことがあるので、少し待って再試行する
for _ in {1..5}; do
    open "$app" 2>/dev/null && break
    sleep 1
done
print "メニューバーのマイクのアイコンから、マイク、アクセシビリティ、日本語の認識モデルの状態を確かめてください。"
print "既定のホットキーは ⌃⌥⌘D（押している間だけ録音）。"
