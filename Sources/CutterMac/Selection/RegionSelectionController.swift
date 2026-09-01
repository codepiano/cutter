import AppKit
import CoreGraphics

@MainActor
final class RegionSelectionController {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<(image: CGImage, output: CaptureSettings.Output)?, Never>?

    func selectRegion(
        from capture: CapturedImage,
        defaultOutput: CaptureSettings.Output,
        windows: [CapturableWindow] = [],
        windowCaptureProvider: (@Sendable (CGWindowID) async throws -> CapturedImage)? = nil
    ) async -> (image: CGImage, output: CaptureSettings.Output)? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay(
                for: capture,
                defaultOutput: defaultOutput,
                windows: windows,
                windowCaptureProvider: windowCaptureProvider
            )
        }
    }

    private func presentOverlay(
        for capture: CapturedImage,
        defaultOutput: CaptureSettings.Output,
        windows: [CapturableWindow],
        windowCaptureProvider: (@Sendable (CGWindowID) async throws -> CapturedImage)?
    ) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == capture.displayID
        }) else {
            finish(with: nil)
            return
        }

        let overlay = RegionSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            capture: capture,
            defaultOutput: defaultOutput,
            captureWindows: windows,
            windowCaptureProvider: windowCaptureProvider
        )
        overlay.onSelection = { [weak self] image, output in
            self?.finish(with: (image, output))
        }
        overlay.onCancel = { [weak self] in
            self?.finish(with: nil)
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.contentView = overlay
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        NSCursor.crosshair.push()
        self.window = window
    }

    private func finish(with result: (image: CGImage, output: CaptureSettings.Output)?) {
        guard let continuation else { return }
        self.continuation = nil
        (window?.contentView as? RegionSelectionView)?.closeAuxiliaryPanels()
        window?.orderOut(nil)
        window = nil
        NSCursor.pop()
        continuation.resume(returning: result)
    }
}
