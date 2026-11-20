#!/bin/zsh
# アプリアイコンを scripts/icon.swift の描画から作る（画像ファイルはリポジトリに置かない）。
# 出力: build.noindex/AppIcon.icns と、確認用の build.noindex/icon-preview-1024.png、build.noindex/icon-preview-32.png。
# Xcode は要らない。iconutil は OS 付属。scripts/bundle.sh から呼ばれる。
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
swiftc scripts/icon.swift -o build.noindex/make-icon
build.noindex/make-icon
