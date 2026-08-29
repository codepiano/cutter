# Cutter

## Platform

macOS 14 or later for the first release.

## Users

Cutter is initially a focused desktop screenshot tool for people who frequently capture, annotate, copy, save, and pin still images on macOS.

## Product Purpose

Make the path from keyboard shortcut to a usable screenshot fast and predictable. Cutter handles still images only; screen recording and video editing are outside the product boundary.

## Operating Context

The app runs quietly from the macOS menu bar. Capture, selection overlays, permissions, global shortcuts, clipboard integration, and floating windows use native macOS behavior.

## Capabilities and Constraints

- First platform: macOS.
- Future architecture: a reusable image-processing core with thin platform-specific shells.
- Native platform code owns screen capture, coordinate conversion, permissions, shortcuts, clipboard behavior, and window management.
- The reusable core will own image transforms, annotation data, undo/redo, export rules, and later scrolling-image stitching.
- No screen recording or video processing.
- The initial milestone proves native capture before annotation and scrolling capture are added.

## Product Principles

- Capture should open before organizational or configuration UI.
- Common actions should require as few decisions as possible.
- Native platform behavior is part of correctness, not decoration.
- Cross-platform reuse must not force screenshot behavior toward a lowest common denominator.
- Images remain local unless a future product decision explicitly adds sharing.

## Open Decisions

- Exact first-release annotation tool set.
- Whether scrolling capture belongs in version 1.0.
- Windows implementation schedule.
- Distribution channel and signing strategy.
