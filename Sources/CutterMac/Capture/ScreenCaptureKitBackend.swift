import CoreGraphics
import ScreenCaptureKit

actor ScreenCaptureKitBackend: ScreenCaptureBackend {
    func capturePrimaryDisplay() async throws -> CapturedImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let primaryDisplayID = CGMainDisplayID()

        guard let display = content.displays.first(where: { $0.displayID == primaryDisplayID }) else {
            throw ScreenCaptureError.primaryDisplayUnavailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGDisplayPixelsWide(primaryDisplayID))
        configuration.height = Int(CGDisplayPixelsHigh(primaryDisplayID))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        return CapturedImage(
            image: image,
            displayID: primaryDisplayID,
            scaleFactor: Self.scaleFactor(for: primaryDisplayID)
        )
    }

    private static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let logicalWidth = CGDisplayBounds(displayID).width
        guard logicalWidth > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(displayID)) / logicalWidth
    }
}
