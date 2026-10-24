#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.work"
mkdir -p "$build_dir/module-cache"
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Sources/ShortcutEngine.swift" "$project_dir/Sources/InputSourceSelection.swift" \
  "$project_dir/Tests/ShortcutEngineTests.swift" \
  -o "$build_dir/ShortcutEngineTests"
"$build_dir/ShortcutEngineTests"
