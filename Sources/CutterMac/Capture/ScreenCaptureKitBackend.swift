import CoreGraphics
import Foundation
import ScreenCaptureKit

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
        let scale = Self.scaleFactor(for: displayID)
        let displayBounds = CGDisplayBounds(displayID)
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
            scaleFactor: scale
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

final class ScreenCaptureKitRegionSampler: ScrollFrameSampler, @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let displayID: CGDirectDisplayID
    private let scaleFactor: CGFloat
    private let expectedDisplayPixels: CGSize
    private let expectedConfigurationSize: CGSize

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat
    ) {
        self.filter = filter
        self.configuration = configuration
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.expectedDisplayPixels = CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
        self.expectedConfigurationSize = CGSize(width: configuration.width, height: configuration.height)
    }

    func sample() async throws -> CapturedImage {
        try Task.checkCancellation()
        guard CGDisplayIsActive(displayID) != 0,
              CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID)) == expectedDisplayPixels,
              abs(Self.scaleFactor(for: displayID) - scaleFactor) < 0.01 else {
            throw ScreenCaptureError.captureGeometryChanged
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        guard CGSize(width: image.width, height: image.height) == expectedConfigurationSize else {
            throw ScreenCaptureError.captureGeometryChanged
        }
        return CapturedImage(image: image, displayID: displayID, scaleFactor: scaleFactor)
    }

    func cancel() async {}

    private static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let logicalWidth = CGDisplayBounds(displayID).width
        guard logicalWidth > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(displayID)) / logicalWidth
    }
}
