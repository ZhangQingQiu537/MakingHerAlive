#!/bin/bash
# 编译（只生成可执行文件，不打 .app 包）
set -e
cd "$(dirname "$0")"
SRC=()
for f in Sources/*.swift; do
  [ "$(basename "$f")" = "main.swift" ] && continue
  SRC+=("$f")
done
mkdir -p build
swiftc -O -parse-as-library -Xfrontend -disable-sandbox \
  -o build/Companion App/Main.swift "${SRC[@]}" \
  -framework SwiftUI -framework AppKit -framework WebKit -framework AVFoundation
echo "✅ build/Companion"
