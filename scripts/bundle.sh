#!/bin/zsh
# build/Dictate.app を組む。許可（マイク、アクセシビリティ）をターミナルでなくアプリに付けるため、
# 実行ファイルを直接起動せずバンドルにする。
# 使い方: scripts/bundle.sh [--no-build] [署名 ID]
#   署名 ID の省略時は、キーチェーンに自己署名の証明書「Dictate Dev」があればそれで署名する。
#   無ければアドホック署名になり、組み直すたびに OS が別のアプリとして扱うので、許可の付け直しが要る。
#   --no-build は、直前の swift build -c release の結果からバンドルだけ作る（Homebrew の formula が使う）。
set -euo pipefail
cd "${0:A:h}/.."
build=1
if [[ "${1:-}" == --no-build ]]; then
    build=0
    shift
fi
if (( $# )); then
    identity="$1"
elif security find-identity -p codesigning | grep -q '"Dictate Dev"'; then
    identity="Dictate Dev"
else
    identity="-"
fi

if (( build )); then
    swift build -c release
fi
scripts/make-icon.sh
app=build/Dictate.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Dictate "$app/Contents/MacOS/Dictate"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.rererr.dictate</string>
    <key>CFBundleName</key><string>Dictate</string>
    <key>CFBundleExecutable</key><string>Dictate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>ホットキーを押している間の発話を文字にするために、マイクを使います。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>発話を端末内で文字にするために、音声認識を使います。</string>
</dict>
</plist>
PLIST
codesign --force --sign "$identity" "$app"
echo "built $app（署名: $identity）"
