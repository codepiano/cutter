import CoreGraphics
import Foundation
import ScreenCaptureKit

// CGDisplayPixelsWide/High can report logical dimensions on Retina displays.
// The active mode's pixel dimensions describe the full render buffer, including
// scaled modes (for example 1440 x 900 points rendered at 2880 x 1800 pixels).
struct DisplayCaptureGeometry: Equatable, Sendable {
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    var scaleFactor: CGFloat { CGFloat(pixelWidth) / bounds.width }

    static func current(for displayID: CGDirectDisplayID) throws -> Self {
        let bounds = CGDisplayBounds(displayID)
        guard CGDisplayIsActive(displayID) != 0,
              let mode = CGDisplayCopyDisplayMode(displayID),
              bounds.width > 0, bounds.height > 0,
              mode.pixelWidth > 0, mode.pixelHeight > 0 else {
            throw ScreenCaptureError.primaryDisplayUnavailable
        }
        return Self(bounds: bounds, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight)
    }
}

actor ScreenCaptureKitBackend: ScreenCaptureBackend {
    func prepareScrollSampler(
        displayID: CGDirectDisplayID,
        region: CGRect,
        includeCursor: Bool
    ) async throws -> any ScrollFrameSampler {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.primaryDisplayUnavailable
        }
        guard let ownApplication = content.applications.first(where: {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }) else { throw ScreenCaptureError.captureFilterUnavailable }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [ownApplication],
            exceptingWindows: []
        )
        let geometry = try DisplayCaptureGeometry.current(for: displayID)
        let scale = geometry.scaleFactor
        let displayBounds = geometry.bounds
        // AppKit region is bottom-left; ScreenCaptureKit sourceRect is display
        // local top-left points.
        let sourceRect = CGRect(
            x: region.minX,
            y: displayBounds.height - region.maxY,
            width: region.width,
            height: region.height
        ).intersection(CGRect(origin: .zero, size: displayBounds.size))
        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw ScreenCaptureError.primaryDisplayUnavailable
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false
        configuration.shouldBeOpaque = false
        return ScreenCaptureKitRegionSampler(
            filter: filter,
            configuration: configuration,
            displayID: displayID,
            geometry: geometry
        )
    }

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
        let geometry = try DisplayCaptureGeometry.current(for: displayID)
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedImage(
            image: image,
            displayID: displayID,
            scaleFactor: geometry.scaleFactor
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
}

final class ScreenCaptureKitRegionSampler: ScrollFrameSampler, @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let displayID: CGDirectDisplayID
    private let geometry: DisplayCaptureGeometry
    private let expectedConfigurationSize: CGSize

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        displayID: CGDirectDisplayID,
        geometry: DisplayCaptureGeometry
    ) {
        self.filter = filter
        self.configuration = configuration
        self.displayID = displayID
        self.geometry = geometry
        self.expectedConfigurationSize = CGSize(width: configuration.width, height: configuration.height)
    }

    func sample() async throws -> CapturedImage {
        try Task.checkCancellation()
        guard let currentGeometry = try? DisplayCaptureGeometry.current(for: displayID),
              currentGeometry == geometry else {
            throw ScreenCaptureError.captureGeometryChanged
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        guard let completedGeometry = try? DisplayCaptureGeometry.current(for: displayID),
              completedGeometry == geometry,
              CGSize(width: image.width, height: image.height) == expectedConfigurationSize else {
            throw ScreenCaptureError.captureGeometryChanged
        }
        return CapturedImage(image: image, displayID: displayID, scaleFactor: geometry.scaleFactor)
    }

    func cancel() async {}
}
