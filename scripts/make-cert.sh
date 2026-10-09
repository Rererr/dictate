#!/bin/zsh
# コード署名用の自己署名証明書「Dictate Dev」をログインキーチェーンに作る。
# これがあると scripts/bundle.sh が自動でこれで署名し、組み直してもアクセシビリティの許可が保たれる。
# 使い方: scripts/make-cert.sh           作る（この Mac の中だけで有効）
#         scripts/make-cert.sh --delete  消す
set -euo pipefail
name="Dictate Dev"

if [[ "${1:-}" == --delete ]]; then
    security delete-identity -c "$name"
    print "消しました: $name"
    exit 0
fi
if security find-identity -p codesigning | grep -q "\"$name\""; then
    print "あります: $name（作りません）"
    exit 0
fi

# OS 付属の LibreSSL を使う。Homebrew の OpenSSL 3 が作る p12 は、キーチェーンへの取り込みが
# 「MAC verification failed」で失敗する（既定の暗号方式を security import が読めない）
openssl=/usr/bin/openssl
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
password="$($openssl rand -hex 16)"
# 鍵生成の進捗表示を消すため stderr を取り、失敗したときだけ見せる
$openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 \
    -subj "/CN=$name" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    2>"$work/err" || { cat "$work/err" >&2; exit 1 }
$openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -out "$work/id.p12" -passout "pass:$password"
# -T で codesign がこの鍵を確認なしに使えるようにする。同じユーザーの他のプロセスも codesign 経由で
# この署名を作れるようになる（README「署名と許可」に開示）
security import "$work/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$password" -T /usr/bin/codesign >/dev/null
print "作りました: $name"
print "次の scripts/bundle.sh または scripts/install.sh からこれで署名します。"
print "アドホック署名で付けた許可は引き継がれないので、一度だけ付け直しが要ります（メニューの「アクセシビリティの許可を付け直す」）。"
