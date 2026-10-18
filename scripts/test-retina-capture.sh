#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
output_dir="$project_dir/.build/retina-capture-tests"
mkdir -p "$output_dir"
swiftc -parse-as-library \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureKitBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ImageFileWriter.swift" \
  "$project_dir/scripts/RetinaCaptureHarness.swift" \
  -o "$output_dir/RetinaCaptureHarness" -framework AppKit -framework ScreenCaptureKit
"$output_dir/RetinaCaptureHarness" "$@"
