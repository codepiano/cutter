#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/.build/scroll-ui-tests"
mkdir -p "$OUTPUT_DIR"
swiftc -parse-as-library -emit-module -emit-object -module-name CutterCore \
  "$PROJECT_DIR"/Sources/CutterCore/*.swift \
  -o "$OUTPUT_DIR/CutterCore.o" -emit-module-path "$OUTPUT_DIR/CutterCore.swiftmodule"
swiftc -o .build/scroll-ui-harness \
  -parse-as-library scripts/ScrollUIHarness.swift \
  "$PROJECT_DIR"/Sources/CutterMac/Capture/CaptureSettings.swift \
  "$PROJECT_DIR"/Sources/CutterMac/Capture/ScreenCaptureBackend.swift \
  "$PROJECT_DIR"/Sources/CutterMac/Capture/ScrollCaptureSession.swift \
  "$PROJECT_DIR"/Sources/CutterMac/Selection/ScrollCaptureHUDController.swift \
  "$PROJECT_DIR"/Sources/CutterMac/Application/LongImagePreviewController.swift \
  "$PROJECT_DIR"/Sources/CutterMac/Application/PinnedImageWindowController.swift \
  "$OUTPUT_DIR/CutterCore.o" -I "$OUTPUT_DIR"
.build/scroll-ui-harness "$OUTPUT_DIR"
