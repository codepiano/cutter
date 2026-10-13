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
- Current capture modes: smart normal-window selection, free region selection, and vertical capture with automatic scrolling and overlap stitching on the primary display (manual scrolling remains available); Space toggles window recognition before selection.
- Current editing: rectangle, square, circle, and transparent perforated stamp selections; precise pixel dimensions; persistent built-in and custom size presets; pen, line, arrow, numeric-label, letter-label, rectangle, text, highlight, random-content mosaic, and random-content blur annotations with quick and arbitrary system colors; multi-selection, duplication, z-order, alignment, line-width, and font-size editing; undo and redo.
- Current outputs: copy, save to the local Pictures directory, copy and save, or open a temporary floating pin without file persistence.
- Capture scheduling: immediate, 3-second, 5-second, or 10-second delay with a cancellable native countdown HUD.
- Future architecture: a reusable image-processing core with thin platform-specific shells.
- Native platform code owns screen capture, coordinate conversion, permissions, shortcuts, clipboard behavior, and window management.
- The reusable core will own image transforms, annotation data, undo/redo, export rules, and later scrolling-image stitching.
- No accounts, network upload, cloud synchronization, screen recording, or video processing.
- Scrolling capture supports pause/resume, undoing the last segment, bounded in-memory stitching, and a scrollable long-image preview with existing outputs. Automatic scrolling requires event-posting permission, uses small steps gated by successful stitching, and pauses on target changes, unreliable matching, persistent instability, or repeated unchanged content. Mode changes and undo pause capture. Long-image annotations and automatic removal of sticky headers remain outside the current scope.
- Full-screen capture and multi-display selection are not implemented yet.

## Product Principles

- Capture should open before organizational or configuration UI.
- Common actions should require as few decisions as possible.
- Native platform behavior is part of correctness, not decoration.
- Cross-platform reuse must not force screenshot behavior toward a lowest common denominator.
- Images remain local unless a future product decision explicitly adds sharing.

## Open Decisions

- Windows implementation schedule.
- Distribution channel and signing strategy.
