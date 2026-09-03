#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
output_dir="$project_dir/.build/toolbar-layout"
mkdir -p "$output_dir"
swiftc -parse-as-library \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSettings.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSizePreset.swift" \
  "$project_dir/Sources/CutterMac/Selection/RegionSelectionView.swift" \
  "$project_dir/scripts/ToolbarLayoutHarness.swift" \
  -o "$output_dir/ToolbarLayoutHarness" -framework AppKit -framework CoreGraphics -framework CoreImage
"$output_dir/ToolbarLayoutHarness" "$output_dir"
