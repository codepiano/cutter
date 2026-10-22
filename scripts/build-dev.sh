#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
output_dir="$project_dir/.build/manual"

mkdir -p "$output_dir"

swiftc \
  -parse-as-library \
  -emit-module -emit-object \
  -module-name CutterCore \
  -emit-module-path "$output_dir/CutterCore.swiftmodule" \
  "$project_dir/Sources/CutterCore/VerticalImageStitcher.swift" \
  -o "$output_dir/CutterCore.o" \
  -framework CoreGraphics

swiftc \
  -parse-as-library \
  -I "$output_dir" \
  "$output_dir/CutterCore.o" \
  "$project_dir/Sources/CutterMac/CutterMain.swift" \
  "$project_dir/Sources/CutterMac/Application/SingleInstanceLock.swift" \
  "$project_dir/Sources/CutterMac/Application/AppDelegate.swift" \
  "$project_dir/Sources/CutterMac/Application/PinnedImageWindowController.swift" \
  "$project_dir/Sources/CutterMac/Application/LongImagePreviewController.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureKitBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/ScrollCaptureSession.swift" \
  "$project_dir/Sources/CutterMac/Capture/AutomaticScrollDriver.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSettings.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureCountdownController.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSizePreset.swift" \
  "$project_dir/Sources/CutterMac/Capture/ImageFileWriter.swift" \
  "$project_dir/Sources/CutterMac/Permissions/ScreenCapturePermission.swift" \
  "$project_dir/Sources/CutterMac/Clipboard/ImageClipboard.swift" \
  "$project_dir/Sources/CutterMac/Selection/RegionSelectionController.swift" \
  "$project_dir/Sources/CutterMac/Selection/RegionSelectionView.swift" \
  "$project_dir/Sources/CutterMac/Selection/ScrollCaptureHUDController.swift" \
  "$project_dir/Sources/CutterMac/Shortcuts/GlobalShortcutService.swift" \
  -o "$output_dir/CutterMac" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework ScreenCaptureKit

print "$output_dir/CutterMac"
