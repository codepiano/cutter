#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
output_dir="$project_dir/.build/scroll-auto-desktop-tests"
mkdir -p "$output_dir"
swiftc -parse-as-library -emit-module -emit-object -module-name CutterCore \
  -emit-module-path "$output_dir/CutterCore.swiftmodule" \
  "$project_dir/Sources/CutterCore/VerticalImageStitcher.swift" \
  -o "$output_dir/CutterCore.o" -framework CoreGraphics
swiftc -parse-as-library -I "$output_dir" "$output_dir/CutterCore.o" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureKitBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScrollCaptureSession.swift" \
  "$project_dir/Sources/CutterMac/Capture/AutomaticScrollDriver.swift" \
  "$project_dir/Sources/CutterMac/Selection/ScrollCaptureHUDController.swift" \
  "$project_dir/scripts/AutoScrollDesktopHarness.swift" \
  -o "$output_dir/AutoScrollDesktopHarness" -framework AppKit -framework ScreenCaptureKit
"$output_dir/AutoScrollDesktopHarness"
