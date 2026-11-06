#!/bin/bash
set -euo pipefail
tests_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$tests_dir/.." && pwd)"
test_dir="$(mktemp -d)"
test_binary="$test_dir/app-tests"
trap 'rm -rf "$test_dir"' EXIT
cp -R "$project_dir/Sources" "$test_dir/Sources"
cp "$tests_dir/AppTests.swift" "$test_dir/AppTests.swift"
/usr/bin/xcrun swiftc -swift-version 5 \
  "$test_dir/Sources/Models.swift" "$test_dir/Sources/Inventory.swift" \
  "$test_dir/Sources/Engine.swift" "$test_dir/Sources/PresetModels.swift" \
  "$test_dir/Sources/PresetEngine.swift" "$test_dir/Sources/PresetWindow.swift" \
  "$test_dir/Sources/App.swift" "$test_dir/AppTests.swift" -o "$test_binary"
"$test_binary"
