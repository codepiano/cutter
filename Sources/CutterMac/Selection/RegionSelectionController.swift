import AppKit
import CoreGraphics

@MainActor
final class RegionSelectionController {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGImage?, Never>?

    func selectRegion(from capture: CapturedImage) async -> CGImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay(for: capture)
        }
    }

    private func presentOverlay(for capture: CapturedImage) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == capture.displayID
        }) else {
            finish(with: nil)
            return
        }

        let overlay = RegionSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            capture: capture
        )
        overlay.onSelection = { [weak self] image in
            self?.finish(with: image)
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
        window.contentView = overlay
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        NSCursor.crosshair.push()
        self.window = window
    }

    private func finish(with image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil
        window?.orderOut(nil)
        window = nil
        NSCursor.pop()
        continuation.resume(returning: image)
    }
}
