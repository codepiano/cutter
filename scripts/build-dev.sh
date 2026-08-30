#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
output_dir="$project_dir/.build/manual"

mkdir -p "$output_dir"

swiftc \
  -parse-as-library \
  "$project_dir/Sources/CutterMac/CutterMain.swift" \
  "$project_dir/Sources/CutterMac/Application/AppDelegate.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureKitBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSettings.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSizePreset.swift" \
  "$project_dir/Sources/CutterMac/Capture/ImageFileWriter.swift" \
  "$project_dir/Sources/CutterMac/Permissions/ScreenCapturePermission.swift" \
  "$project_dir/Sources/CutterMac/Clipboard/ImageClipboard.swift" \
  "$project_dir/Sources/CutterMac/Selection/RegionSelectionController.swift" \
  "$project_dir/Sources/CutterMac/Selection/RegionSelectionView.swift" \
  "$project_dir/Sources/CutterMac/Shortcuts/GlobalShortcutService.swift" \
  -o "$output_dir/CutterMac" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ScreenCaptureKit

print "$output_dir/CutterMac"
