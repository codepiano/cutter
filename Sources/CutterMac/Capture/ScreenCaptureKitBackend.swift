import CoreGraphics
import Foundation
import ScreenCaptureKit

actor ScreenCaptureKitBackend: ScreenCaptureBackend {
    func preparePrimaryDisplay(includeCursor: Bool) async throws -> CaptureWorkspace {
        let content = try await shareableContent()
        let primaryDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == primaryDisplayID }) else {
            throw ScreenCaptureError.primaryDisplayUnavailable
        }

        let displayCapture = try await captureDisplay(
            display,
            displayID: primaryDisplayID,
            includeCursor: includeCursor
        )
        return CaptureWorkspace(
            display: displayCapture,
            windows: capturableWindows(from: content, on: primaryDisplayID)
        )
    }

    func captureWindow(id: CGWindowID, includeCursor: Bool) async throws -> CapturedImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw ScreenCaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pointScale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * pointScale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * pointScale).rounded()))
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false
        configuration.shouldBeOpaque = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedImage(
            image: image,
            displayID: displayID(containing: window.frame) ?? CGMainDisplayID(),
            scaleFactor: pointScale
        )
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }
        return try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }

    private func captureDisplay(
        _ display: SCDisplay,
        displayID: CGDirectDisplayID,
        includeCursor: Bool
    ) async throws -> CapturedImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGDisplayPixelsWide(displayID))
        configuration.height = Int(CGDisplayPixelsHigh(displayID))
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedImage(
            image: image,
            displayID: displayID,
            scaleFactor: Self.scaleFactor(for: displayID)
        )
    }

    private func capturableWindows(
        from content: SCShareableContent,
        on displayID: CGDirectDisplayID
    ) -> [CapturableWindow] {
        let displayBounds = CGDisplayBounds(displayID)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let order = frontToBackWindowOrder()
        return content.windows.compactMap { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  displayBounds.contains(window.frame),
                  window.frame.width >= 80,
                  window.frame.height >= 40,
                  let application = window.owningApplication,
                  application.processID != ProcessInfo.processInfo.processIdentifier,
                  application.bundleIdentifier != ownBundleIdentifier else {
                return nil
            }
            return CapturableWindow(
                id: window.windowID,
                frame: window.frame,
                displayID: displayID,
                title: window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                ownerName: application.applicationName
            )
        }.sorted { lhs, rhs in
            (order[lhs.id] ?? Int.max) < (order[rhs.id] ?? Int.max)
        }
    }

    private func frontToBackWindowOrder() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var result: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            result[CGWindowID(number.uint32Value)] = index
        }
        return result
    }

    private func displayID(containing windowFrame: CGRect) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first(where: { CGDisplayBounds($0).intersects(windowFrame) })
    }

    private static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let logicalWidth = CGDisplayBounds(displayID).width
        guard logicalWidth > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(displayID)) / logicalWidth
    }
}
