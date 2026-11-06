#!/bin/bash
set -euo pipefail
tests_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$tests_dir/.." && pwd)"
test_binary="$tests_dir/.engine-tests-$$"
trap 'if [[ -e "$test_binary" ]]; then rm "$test_binary"; fi' EXIT
/usr/bin/xcrun swiftc \
  "$project_dir/Sources/Models.swift" \
  "$project_dir/Sources/Inventory.swift" \
  "$project_dir/Sources/Engine.swift" \
  "$tests_dir/EngineTests.swift" \
  -o "$test_binary"
PLUGIN_PORTER_TEST_ROOT="$tests_dir" "$test_binary"
