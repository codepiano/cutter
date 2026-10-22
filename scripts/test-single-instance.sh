#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
output_dir="$project_dir/.build/single-instance-tests"
mkdir -p "$output_dir"
swiftc -parse-as-library \
  "$project_dir/Sources/CutterMac/Application/SingleInstanceLock.swift" \
  "$project_dir/Sources/CutterMac/Shortcuts/GlobalShortcutService.swift" \
  "$project_dir/scripts/SingleInstanceHarness.swift" \
  -o "$output_dir/SingleInstanceHarness" -framework AppKit -framework Carbon
"$output_dir/SingleInstanceHarness"
