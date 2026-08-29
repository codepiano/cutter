# Cutter Architecture

## Boundary

The architecture separates reusable image semantics from operating-system integration.

```text
User action
    |
macOS shell
    |-- permissions
    |-- screen and window discovery
    |-- selection overlay and coordinate conversion
    |-- clipboard, shortcuts, and floating windows
    |
Captured image boundary
    |
cross-platform core (planned Rust crate)
    |-- image transforms
    |-- annotation document and rendering
    |-- undo and redo
    |-- encoding and export policy
    `-- scrolling-image stitching
```

The shell passes images across the boundary in physical pixels. It also supplies color-space and scale metadata. Annotation coordinates are expressed in image-pixel space, so Retina and mixed-DPI screen geometry never leaks into the reusable core.

## macOS modules

- `Application`: menu-bar lifecycle and user-facing commands.
- `Capture`: a small `ScreenCaptureBackend` interface and the ScreenCaptureKit implementation.
- `Permissions`: screen-capture authorization checks and requests.
- `Clipboard`: native image publication.

The application layer asks for a screenshot. It does not know how ScreenCaptureKit discovers displays, constructs filters, or configures pixel dimensions.

## Cross-platform core

The reusable core is deliberately not implemented in Swift. The intended implementation is Rust with a small C-compatible or generated bridge. Rust is not currently installed on this development machine, so this milestone stops at the native boundary instead of creating temporary Swift image-domain code that would later need to be replaced.

## Next vertical slice

The next slice is region capture:

1. Freeze one image for each display.
2. Present one native borderless overlay per display.
3. Convert the drag selection into physical image-pixel rectangles.
4. Crop from the frozen image rather than recapturing after selection.
5. Copy the result and expose save/edit/pin actions.

Freezing first makes the selected pixels deterministic and prevents overlay UI from appearing in the final capture.
