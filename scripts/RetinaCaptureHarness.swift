import AppKit
import ScreenCaptureKit

@main
private struct RetinaCaptureHarness {
    @MainActor static func main() async throws {
        // Distinguish Retina render pixels from both logical points and panel
        // resolution; scaled Retina modes may render above the panel resolution.
        let standard = DisplayCaptureGeometry(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080)
        let retina = DisplayCaptureGeometry(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), pixelWidth: 2880, pixelHeight: 1800)
        let moved = DisplayCaptureGeometry(bounds: CGRect(x: -1440, y: 100, width: 1440, height: 900), pixelWidth: 2880, pixelHeight: 1800)
        let changed = DisplayCaptureGeometry(bounds: retina.bounds, pixelWidth: 1440, pixelHeight: 900)
        precondition(standard.scaleFactor == 1 && retina.scaleFactor == 2 && moved.scaleFactor == 2)
        precondition(retina != changed && retina != moved, "Sampling must detect scale and display placement changes")
        print("Display geometry regression passed: 1x, scaled Retina 2x, mode and placement changes")

        guard CommandLine.arguments.contains("--desktop") else { return }
        guard CGPreflightScreenCaptureAccess() else {
            print("Desktop regression blocked: screen recording permission is required")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })!
        // Give the sampler an application/window to exclude, without taking focus.
        let marker = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20, width: 8, height: 8), styleMask: .borderless, backing: .buffered, defer: false)
        marker.ignoresMouseEvents = true
        marker.orderFrontRegardless()
        defer { marker.orderOut(nil) }
        let backend = ScreenCaptureKitBackend()
        let workspace = try await backend.preparePrimaryDisplay(includeCursor: false)
        let capture = workspace.display
        let expectedWidth = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let expectedHeight = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        precondition(capture.image.width == expectedWidth && capture.image.height == expectedHeight)
        precondition(capture.scaleFactor == screen.backingScaleFactor)
        let region = CGRect(x: 40, y: 40, width: 240, height: 160)
        let sampler = try await backend.prepareScrollSampler(displayID: capture.displayID, region: region, includeCursor: false)
        let frame = try await sampler.sample()
        precondition(frame.image.width == Int(region.width * screen.backingScaleFactor))
        precondition(frame.image.height == Int(region.height * screen.backingScaleFactor))
        precondition(frame.scaleFactor == capture.scaleFactor)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cutter-retina-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for image in [capture.image, frame.image] {
            let file = try ImageFileWriter.savePNG(image, to: directory)
            let decoded = NSBitmapImageRep(data: try Data(contentsOf: file))!
            precondition(decoded.pixelsWide == image.width && decoded.pixelsHigh == image.height)
        }
        await sampler.cancel()
        print("Live Retina capture and PNG roundtrip passed: display=\(capture.image.width)x\(capture.image.height), scroll=\(frame.image.width)x\(frame.image.height), scale=\(capture.scaleFactor)")
    }
}
