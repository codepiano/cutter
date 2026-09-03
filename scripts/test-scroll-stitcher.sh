#!/bin/zsh

set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
build_dir="$project_dir/.build/manual"
mkdir -p "$build_dir"
swiftc \
  "$project_dir/Sources/CutterCore/VerticalImageStitcher.swift" \
  "$project_dir/scripts/ScrollStitcherHarness.swift" \
  -parse-as-library \
  -o "$build_dir/ScrollStitcherHarness" \
  -framework CoreGraphics
"$build_dir/ScrollStitcherHarness"
