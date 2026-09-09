#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
output_dir="$project_dir/.build/toolbar-layout"
mkdir -p "$output_dir"
app_bundle="$output_dir/ToolbarLayoutHarness.app"
executable="$app_bundle/Contents/MacOS/ToolbarLayoutHarness"
mkdir -p "$app_bundle/Contents/MacOS"
swiftc -parse-as-library \
  "$project_dir/Sources/CutterMac/Capture/ScreenCaptureBackend.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSettings.swift" \
  "$project_dir/Sources/CutterMac/Capture/CaptureSizePreset.swift" \
  "$project_dir/Sources/CutterMac/Selection/RegionSelectionView.swift" \
  "$project_dir/scripts/ToolbarLayoutHarness.swift" \
  -o "$executable" -framework AppKit -framework CoreGraphics -framework CoreImage
plist="$app_bundle/Contents/Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string "com.codepiano.cutter.toolbar-test" "$plist"
plutil -insert CFBundleName -string "ToolbarLayoutHarness" "$plist"
plutil -insert CFBundleExecutable -string "ToolbarLayoutHarness" "$plist"
plutil -insert CFBundlePackageType -string "APPL" "$plist"
plutil -insert NSHighResolutionCapable -bool true "$plist"
plutil -insert LSUIElement -bool true "$plist"
rm -f "$output_dir/key-window-and-return.passed"
open -W "$app_bundle" --args "$output_dir"
[[ -f "$output_dir/key-window-and-return.passed" ]]
print "Borderless key-window support, Return and keypad Enter passed."
