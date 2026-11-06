#!/bin/bash
set -euo pipefail
tests_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$tests_dir/.." && pwd)"
mkdir -p "$project_dir/.build"
coverage_dir="$(mktemp -d "$project_dir/.build/coverage.XXXXXX")"
snapshot_dir="$coverage_dir/snapshot"
mkdir -p "$snapshot_dir/Sources" "$snapshot_dir/Tests" "$coverage_dir/bin" "$coverage_dir/profiles" "$coverage_dir/fixtures"
cp "$project_dir"/Sources/*.swift "$snapshot_dir/Sources/"
cp "$tests_dir"/*.swift "$snapshot_dir/Tests/"
shasum -a 256 "$snapshot_dir"/Sources/*.swift "$snapshot_dir"/Tests/*.swift > "$coverage_dir/sources.sha256"
/usr/bin/xcrun swiftc --version > "$coverage_dir/toolchain.txt" 2>&1
/usr/bin/sw_vers >> "$coverage_dir/toolchain.txt"
printf 'Coverage snapshot: %s\n' "$coverage_dir"

source_dir="$snapshot_dir/Sources"
test_source_dir="$snapshot_dir/Tests"
core_sources=("$source_dir/Models.swift" "$source_dir/Engine.swift" "$source_dir/PresetModels.swift" "$source_dir/PresetEngine.swift")
# A shared module name lets profiles of common source functions merge across executables.
coverage_flags=(-swift-version 5 -Onone -g -module-name PluginPorterCoverage -profile-generate -profile-coverage-mapping)
export LLVM_PROFILE_FILE="$coverage_dir/profiles/%m-%p.profraw"
export PLUGIN_PORTER_TEST_ROOT="$coverage_dir/fixtures"

compile_suite() {
  local suite="$1"
  shift
  if ! /usr/bin/xcrun swiftc "${coverage_flags[@]}" "$@" -o "$coverage_dir/bin/$suite" > "$coverage_dir/$suite-build.log" 2>&1; then
    cat "$coverage_dir/$suite-build.log" >&2
    exit 1
  fi
}

run_suite() {
  local suite="$1"
  shift
  if ! "$coverage_dir/bin/$suite" "$@" > "$coverage_dir/$suite-test.log" 2>&1; then
    cat "$coverage_dir/$suite-test.log" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$suite"
}

compile_suite engine-tests "$source_dir/Models.swift" "$source_dir/Inventory.swift" "$source_dir/Engine.swift" "$test_source_dir/EngineTests.swift"
run_suite engine-tests
compile_suite preset-tests "${core_sources[@]}" "$test_source_dir/PresetTests.swift"
run_suite preset-tests
# AppTests injects an empty inventory loader; no real plug-ins are scanned or installed.
compile_suite app-tests "${core_sources[@]}" "$source_dir/Inventory.swift" "$source_dir/PresetWindow.swift" "$source_dir/App.swift" "$test_source_dir/AppTests.swift"
run_suite app-tests

printf 'func runGUI() { fatalError("GUI is not available in CLI tests") }\n' > "$snapshot_dir/GUIStub.swift"
# Instrument the actual command implementation as well as its harness. Child processes
# inherit LLVM_PROFILE_FILE, whose PID/module fields keep their profiles separate.
compile_suite pluginporter "${core_sources[@]}" "$test_source_dir/CLIInventoryFixture.swift" "$snapshot_dir/GUIStub.swift" "$source_dir/main.swift"
compile_suite cli-tests "${core_sources[@]}" "$test_source_dir/CLITests.swift"
PLUGIN_PORTER_REAL_SCANNER=0 run_suite cli-tests "$coverage_dir/bin/pluginporter"

/usr/bin/xcrun llvm-profdata merge --sparse --failure-mode=any "$coverage_dir"/profiles/*.profraw -o "$coverage_dir/merged.profdata"
coverage_objects=("$coverage_dir/bin/engine-tests" -object "$coverage_dir/bin/preset-tests" -object "$coverage_dir/bin/app-tests" -object "$coverage_dir/bin/pluginporter" -object "$coverage_dir/bin/cli-tests" -instr-profile "$coverage_dir/merged.profdata")
/usr/bin/xcrun llvm-cov report "${coverage_objects[@]}" "$source_dir"/*.swift > "$coverage_dir/report.txt"
/usr/bin/xcrun llvm-cov export "${coverage_objects[@]}" "$source_dir"/*.swift > "$coverage_dir/coverage.json"
/usr/bin/xcrun llvm-cov report "${coverage_objects[@]}" "${core_sources[@]}" "$source_dir/Inventory.swift" > "$coverage_dir/core-report.txt"
cat "$coverage_dir/report.txt"
printf '\nCore-only coverage (excludes GUI/CLI):\n'
cat "$coverage_dir/core-report.txt"
printf '\nSource snapshots, logs and machine-readable coverage: %s\n' "$coverage_dir"
