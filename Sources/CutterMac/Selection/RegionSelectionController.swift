import AppKit
import CoreGraphics

@MainActor
final class RegionSelectionController {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<(image: CGImage, output: CaptureSettings.Output)?, Never>?
    private var scrollHUD: ScrollCaptureHUDController?
    private var scrollPreview: LongImagePreviewController?
    private var scrollSamplerProvider: (@Sendable (CGDirectDisplayID, CGRect) async throws -> any ScrollFrameSampler)?
    private var scrollTask: Task<Void, Never>?
    private var scrollGeneration: UInt64 = 0
    private var borderWindow: NSWindow?
    private var cursorPushed = false
    private var captureScreen: NSScreen?
    private var ownsApplicationFocus = false

    func cancel() { finish(with: nil) }

    func selectRegion(
        from capture: CapturedImage,
        defaultOutput: CaptureSettings.Output,
        windows: [CapturableWindow] = [],
        windowCaptureProvider: (@Sendable (CGWindowID) async throws -> CapturedImage)? = nil,
        scrollSamplerProvider: (@Sendable (CGDirectDisplayID, CGRect) async throws -> any ScrollFrameSampler)? = nil
    ) async -> (image: CGImage, output: CaptureSettings.Output)? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.scrollSamplerProvider = scrollSamplerProvider
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
        overlay.onScrollSelection = { [weak self, weak overlay] region in
            self?.startScrollCapture(region: region, displayID: capture.displayID, scaleFactor: capture.scaleFactor, overlay: overlay)
        }

        let window = RegionSelectionWindow(
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
        NSApp.activate()
        ownsApplicationFocus = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        NSCursor.crosshair.push()
        cursorPushed = true
        self.window = window
    }

    private func startScrollCapture(region: CGRect, displayID: CGDirectDisplayID, scaleFactor: CGFloat, overlay: RegionSelectionView?) {
        guard scrollHUD == nil, scrollTask == nil, let provider = scrollSamplerProvider else { return }
        scrollGeneration &+= 1
        let token = scrollGeneration
        let sourceWindow = window
        sourceWindow?.ignoresMouseEvents = true
        (sourceWindow?.contentView as? RegionSelectionView)?.closeAuxiliaryPanels()
        sourceWindow?.orderOut(nil)
        releaseApplicationFocus()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        if let screen = sourceWindow?.screen {
            captureScreen = screen
            let frame = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.minY + region.minY, width: region.width, height: region.height)
            let border = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            border.isOpaque = false; border.backgroundColor = .clear; border.level = .floating; border.ignoresMouseEvents = true; border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            border.contentView = ScrollRegionBorderView(frame: CGRect(origin: .zero, size: region.size)); border.orderFrontRegardless(); borderWindow = border
        }
        scrollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sampler = try await provider(displayID, region)
                guard self.scrollGeneration == token, self.continuation != nil else { await sampler.cancel(); return }
                let session = ScrollCaptureSession(sampler: sampler)
                let hud = ScrollCaptureHUDController(session: session, region: region)
                hud.onFinish = { [weak self] image in
                    self?.showScrollPreview(image, scaleFactor: scaleFactor)
                }
                hud.onCancel = { [weak self] in self?.cancelScrollCapture() }
                self.scrollHUD = hud
                hud.show(on: self.captureScreen)
                try await hud.start()
            } catch {
                guard self.scrollGeneration == token else { return }
                self.cancelScrollCapture()
                let alert = NSAlert(error: error)
                alert.alertStyle = .warning
                alert.runModal()
            }
            self.scrollTask = nil
        }
    }

    private func showScrollPreview(_ image: CGImage, scaleFactor: CGFloat) {
        guard continuation != nil else { return }
        borderWindow?.orderOut(nil)
        borderWindow = nil
        scrollHUD?.close()
        scrollHUD = nil
        let preview = LongImagePreviewController(image: image, scaleFactor: scaleFactor)
        preview.onOutput = { [weak self] image, output in self?.finish(with: (image, output)) }
        preview.onClose = { [weak self] in self?.finish(with: nil) }
        scrollPreview = preview
        NSApp.activate()
        ownsApplicationFocus = true
        preview.show()
    }

    private func cancelScrollCapture() {
        scrollHUD?.cancel()
        scrollHUD?.close()
        scrollHUD = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        captureScreen = nil
        window?.ignoresMouseEvents = false
        finish(with: nil)
    }

    private func finish(with result: (image: CGImage, output: CaptureSettings.Output)?) {
        guard let continuation else { return }
        self.continuation = nil
        scrollGeneration &+= 1
        borderWindow?.orderOut(nil)
        borderWindow = nil
        captureScreen = nil
        (window?.contentView as? RegionSelectionView)?.closeAuxiliaryPanels()
        scrollHUD?.cancel()
        scrollHUD?.close()
        scrollHUD = nil
        scrollPreview?.close()
        scrollPreview = nil
        window?.orderOut(nil)
        window = nil
        releaseApplicationFocus()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        scrollTask?.cancel()
        scrollTask = nil
        continuation.resume(returning: result)
    }

    private func releaseApplicationFocus() {
        guard ownsApplicationFocus else { return }
        ownsApplicationFocus = false
        NSApp.deactivate()
    }
}
