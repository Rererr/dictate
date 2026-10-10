#!/bin/zsh
# 組んだアプリが起動して動き続け、終了できることを、実際に開いて確かめる（スモーク）。
# マイクも認識も許可も使わない --demo で開くので、CI や初めての Mac でも走る。
# 扱うのは build/Dictate.app から自分が起動したプロセスだけで、~/Applications 等で動いている Dictate には触らない。
# 使い方: scripts/e2e.sh            組んでから確かめる
#         scripts/e2e.sh --no-build  直前の scripts/bundle.sh の結果を確かめる
set -euo pipefail
cd "${0:A:h}/.."
app="$PWD/build/Dictate.app"
executable="$app/Contents/MacOS/Dictate"
fail() { print -u2 "e2e.sh: $1"; exit 1 }
# この build の実行ファイルから起動したプロセスの pid（無ければ空）。パスを正規表現にせず、前方一致で見る
ours() {
    ps -axo pid=,command= | while read -r pid cmd; do
        [[ "$cmd" == "$executable" || "$cmd" == "$executable "* ]] && print "$pid"
    done
    return 0
}

if [[ "${1:-}" != --no-build ]]; then
    scripts/bundle.sh
fi
[[ -d "$app" ]] || fail "$app がありません。scripts/bundle.sh で組んでください"

# バンドルの体裁: 署名が通り、Info.plist に常駐アプリと許可の文言がある
codesign --verify --strict "$app" || fail "署名の検証に失敗"
plist="$app/Contents/Info.plist"
plutil -lint "$plist" >/dev/null || fail "Info.plist を読めません"
for key in CFBundleIdentifier CFBundleExecutable LSUIElement NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription LSMinimumSystemVersion; do
    plutil -extract "$key" raw "$plist" >/dev/null 2>&1 || fail "Info.plist に $key がありません"
done
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == com.rererr.dictate ]] || fail "バンドル ID が違います"

# 前回の e2e が残していたものだけ閉じる
if [[ -n "$(ours)" ]]; then
    kill -TERM $(ours) 2>/dev/null || true
    for _ in {1..50}; do [[ -z "$(ours)" ]] && break; sleep 0.1; done
    [[ -z "$(ours)" ]] || fail "前回の e2e のプロセスを終了できません（pid $(ours)）"
fi

# -n で、同じバンドル ID のアプリが動いていても別のインスタンスとして開く
open -n "$app" --args --demo
for _ in {1..100}; do
    [[ -n "$(ours)" ]] && break
    sleep 0.1
done
pid="$(ours)"
[[ -n "$pid" ]] || fail "起動しません（10 秒待ちました）"
# 起動直後に落ちていないことを、少し置いてから確かめる
sleep 2
kill -0 "$pid" 2>/dev/null || fail "起動の直後に終了しました（pid $pid）"

# SIGTERM で終了を求め、消えることを確かめる（メニューの「終了」の経路は通らない。それは --demo で本人が目視する）
kill -TERM "$pid"
for _ in {1..100}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid"; fail "終了を送っても 10 秒たっても残っています（pid $pid）" }
# 通常モード: 隔離した設定ディレクトリ（DICTATE_HOME）で実行ファイルを直接起動し、設定を読んで整形サーバの起動を試みることを見る。
# 起動コマンドは `false`（すぐ 1 で終わる）なので、サーバは立たず、ログに起動の記録と失敗が残る。本人の設定と履歴には触れない
home="$(mktemp -d)/Dictate"
mkdir -p "$home"
cat > "$home/config.json" <<'JSON'
{ "formatter": { "enabled": true, "endpoint": "http://127.0.0.1:8139/v1", "startCommand": "false" } }
JSON
DICTATE_HOME="$home" "$executable" &
pid=$!
sleep 4
kill -0 "$pid" 2>/dev/null || fail "通常モードで起動の直後に終了しました（pid $pid）"
[[ -f "$home/formatter.log" ]] || { kill -TERM "$pid"; fail "隔離した設定を読んでいません（$home/formatter.log が無い）" }
grep -q '^\$ false$' "$home/formatter.log" || { kill -TERM "$pid"; fail "設定の startCommand で起動していません" }
[[ ! -e "$home/history.jsonl" ]] || { kill -TERM "$pid"; fail "発話していないのに履歴が書かれています" }
kill -TERM "$pid"
for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid"; fail "通常モードの終了を送っても 10 秒たっても残っています（pid $pid）" }
rm -rf "${home:h}"
print "e2e.sh: ok（$app を --demo で起動し、2 秒動き続け、SIGTERM で終了。通常モードは隔離した設定で起動し、startCommand を実行して終了しました）"
