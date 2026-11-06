#!/bin/bash
set -euo pipefail
tests_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$tests_dir/.." && pwd)"
work_directory="$(mktemp -d "$tests_dir/.cli-tests.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT
cli_binary="${PLUGIN_PORTER_CLI:-$work_directory/pluginporter}"
if [[ -z "${PLUGIN_PORTER_CLI:-}" ]]; then
  printf 'func runGUI() { fatalError("GUI is not available in CLI tests") }\n' > "$work_directory/GUIStub.swift"
  /usr/bin/xcrun swiftc -swift-version 5 \
    "$project_dir/Sources/Models.swift" "$tests_dir/CLIInventoryFixture.swift" \
    "$project_dir/Sources/Engine.swift" "$project_dir/Sources/PresetModels.swift" \
    "$project_dir/Sources/PresetEngine.swift" "$work_directory/GUIStub.swift" \
    "$project_dir/Sources/main.swift" -o "$cli_binary"
fi
/usr/bin/xcrun swiftc "$project_dir/Sources/Models.swift" \
  "$project_dir/Sources/Engine.swift" "$project_dir/Sources/PresetModels.swift" \
  "$project_dir/Sources/PresetEngine.swift" "$tests_dir/CLITests.swift" \
  -o "$work_directory/cli-tests"
PLUGIN_PORTER_REAL_SCANNER="${PLUGIN_PORTER_CLI:+1}" PLUGIN_PORTER_TEST_ROOT="$work_directory" "$work_directory/cli-tests" "$cli_binary"
