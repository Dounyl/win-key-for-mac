#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.work"
output_app="${1:-$project_dir/release/WinKeyForMac.app}"
mkdir -p "$build_dir/module-cache" "$output_app/Contents/MacOS" "$output_app/Contents/Resources"
bash "$project_dir/scripts/test.sh"
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Sources/ShortcutEngine.swift" \
  "$project_dir/Sources/InputSourceSelection.swift" \
  "$project_dir/Sources/EventMonitor.swift" "$project_dir/Sources/WinKeyForMac.swift" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework Carbon -framework ServiceManagement \
  -o "$output_app/Contents/MacOS/WinKeyForMac"
cp "$project_dir/Info.plist" "$output_app/Contents/Info.plist"
swiftc -module-cache-path "$build_dir/module-cache" "$project_dir/scripts/make-icon.swift" -o "$build_dir/make-icon"
"$build_dir/make-icon" "$output_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$output_app"
codesign --verify --deep --strict "$output_app"
printf 'Built: %s\n' "$output_app"
