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

        let testCapture = CommandLine.arguments.contains("--desktop")
        guard testCapture || CommandLine.arguments.contains("--display-routing") else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screens = NSScreen.screens
        precondition(!screens.isEmpty)
        for screen in screens {
            let displayID = CaptureDisplay.id(for: screen)!
            let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            precondition(CaptureDisplay.at(center) == displayID)
            precondition(CaptureDisplay.screen(for: displayID)?.frame == screen.frame)

            // Use the same screen-relative rectangles as the selection and scroll border.
            // Leave the windows hidden so the test does not steal focus.
            let region = CGRect(x: 40, y: 40, width: 240, height: 160)
            for localFrame in [CGRect(origin: .zero, size: screen.frame.size), region] {
                let window = NSWindow(contentRect: localFrame, styleMask: .borderless, backing: .buffered, defer: true, screen: screen)
                precondition(window.frame == localFrame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            }
        }
        let outside = CGPoint(x: screens.map { $0.frame.maxX }.max()! + 1, y: 0)
        precondition(CaptureDisplay.at(outside) == CGMainDisplayID())
        print("Display routing and window frames passed: \(screens.count) active display(s)")
        guard testCapture else { return }
        guard CGPreflightScreenCaptureAccess() else {
            print("Desktop regression blocked: screen recording permission is required")
            exit(2)
        }
        for screen in screens {
            try await verifyCapture(on: screen)
        }
    }

    @MainActor private static func verifyCapture(on screen: NSScreen) async throws {
        let displayID = CaptureDisplay.id(for: screen)!
        // Give the sampler an application/window to exclude, without taking focus.
        let marker = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20, width: 8, height: 8), styleMask: .borderless, backing: .buffered, defer: false)
        marker.ignoresMouseEvents = true
        marker.orderFrontRegardless()
        defer { marker.orderOut(nil) }
        let backend = ScreenCaptureKitBackend()
        let workspace = try await backend.prepareDisplay(displayID: displayID, includeCursor: false)
        let capture = workspace.display
        precondition(capture.displayID == displayID)
        precondition(workspace.windows.allSatisfy { CGDisplayBounds(displayID).contains($0.frame) })
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
        print("Live display capture and PNG roundtrip passed: display=\(capture.image.width)x\(capture.image.height), scroll=\(frame.image.width)x\(frame.image.height), scale=\(capture.scaleFactor)")
    }
}
