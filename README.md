# Cutter

Cutter is a native macOS screenshot tool focused on still images. The current milestone is a small, compilable menu-bar shell backed by ScreenCaptureKit.

## Current capabilities

- Runs as a menu-bar application.
- Reports macOS screen-capture permission state.
- Freezes the primary display through ScreenCaptureKit.
- Presents a native drag-selection overlay with live pixel dimensions.
- Crops the frozen image and copies the selected region to the system clipboard.
- Registers a global `⌥⌘2` shortcut for capture, including when Cutter is not focused.
- Shows an action bar directly beneath the selection rectangle.
- Lets the user choose copy, save as PNG, or copy-and-save from that action bar.
- Remembers cursor and output preferences locally.

Annotation, pinning, scrolling capture, multi-display selection, and window/full-screen capture are planned but not implemented yet.

## Build the development executable

```sh
swift build
```

SwiftPM produces a development executable rather than a signed `.app` bundle. The repository includes a local ad-hoc packaging script; full Xcode is only needed for the standard `xcodebuild`/XCTest workflow, release entitlements, and distribution signing.

If the active Command Line Tools installation has a SwiftPM `PackageDescription` ABI mismatch, the source can still be compiled directly:

```sh
./scripts/build-dev.sh
```

That fallback validates the native code and creates `.build/manual/CutterMac`; it does not replace the signed app-bundle build.

当前开发环境的 Command Line Tools 不带 XCTest/Swift Testing 模块，因此测试 target 会在完整 Xcode 测试环境接入后补回；现阶段 `swift build` 和直接编译脚本负责源码验证。

To create and launch an ad-hoc signed development app bundle:

```sh
./scripts/build-app.sh
open .build/Cutter.app
```

The development app is signed with the local `Cutter Local Development` identity. On a new Mac, create that identity once:

```sh
./scripts/create-local-signing-identity.sh
```

This certificate and private key stay in the login keychain and are never written to Git. The identity is for local use only; it is not an Apple Developer ID certificate and is not intended for distribution.

## Architecture

The macOS shell owns platform behavior. Cross-platform image logic will live behind a narrow bridge and will not depend on AppKit or ScreenCaptureKit. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
