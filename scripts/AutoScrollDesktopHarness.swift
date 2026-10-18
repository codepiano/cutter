import AppKit
import CoreGraphics
import Foundation

private final class FixtureView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for y in stride(from: max(0, Int(dirtyRect.minY) / 4 * 4), to: min(1600, Int(dirtyRect.maxY) + 4), by: 4) {
            for x in stride(from: 0, to: 280, by: 4) {
                let v = CGFloat((x * 17 + y * 29 + ((x / 7 + y / 5) % 2) * 61) & 255) / 255
                NSColor(calibratedRed: v, green: 0.2 + v * 0.5, blue: 1 - v * 0.7, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 4, height: 4).fill()
            }
        }
    }
}

@main
private struct AutoScrollDesktopHarness {
    @MainActor static var fixtureWindow: NSWindow?
    @MainActor static var fixtureTimer: Timer?

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if args.contains("--target") {
            showTarget(metadata: URL(fileURLWithPath: args.last!))
        } else {
            Task { @MainActor in
                do { try await verifyDesktop() }
                catch { print("Automatic desktop regression failed: \(error)"); exit(1) }
                app.terminate(nil)
            }
        }
        app.run()
    }

    @MainActor private static func showTarget(metadata: URL) {
        let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })!
        let screenFrame = screen.frame
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.minY + 100, width: 280, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Cutter 自动滚动测试内容"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.documentView = FixtureView(frame: CGRect(x: 0, y: 0, width: 280, height: 1600))
        window.contentView = scroll
        fixtureWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        scroll.contentView.scroll(to: .zero)
        fixtureTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let rect = window.convertToScreen(scroll.convert(scroll.contentView.frame, to: nil))
                let payload: [String: Double] = ["x": rect.minX - screenFrame.minX, "y": rect.minY - screenFrame.minY, "width": rect.width, "height": rect.height, "offset": scroll.contentView.bounds.minY]
                try? JSONSerialization.data(withJSONObject: payload).write(to: metadata, options: .atomic)
            }
        }
    }

    @MainActor private static func verifyDesktop() async throws {
        guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else {
            print("Desktop regression blocked: screen recording and event posting permissions are required")
            exit(2)
        }
        let directory = URL(fileURLWithPath: ".build/scroll-auto-desktop-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appendingPathComponent("viewport-\(UUID().uuidString).json")
        let target = Process()
        target.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        target.arguments = ["--target", metadata.path]
        try target.run()
        defer {
            if target.isRunning { target.terminate(); target.waitUntilExit() }
            try? FileManager.default.removeItem(at: metadata)
        }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: metadata.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        func read() throws -> [String: Double] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Double]
        }
        let initial = try read()
        let region = CGRect(x: initial["x"]! + 4, y: initial["y"]! + 4, width: initial["width"]! - 8, height: initial["height"]! - 8)
        // Like Cutter's live selection border, this gives ScreenCaptureKit a
        // visible window for our own app to exclude. Its magenta pixels must
        // not appear in the captured content.
        let mainScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })!
        let marker = NSWindow(contentRect: CGRect(x: mainScreen.frame.minX + region.minX + 8, y: mainScreen.frame.minY + region.minY + 8, width: 30, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
        marker.backgroundColor = .magenta
        marker.level = .floating
        marker.ignoresMouseEvents = true
        marker.orderFrontRegardless()
        defer { marker.orderOut(nil) }
        let backend = ScreenCaptureKitBackend()
        let sampler = try await backend.prepareScrollSampler(displayID: CGMainDisplayID(), region: region, includeCursor: false)
        let driver = AutomaticScrollDriver(displayID: CGMainDisplayID(), region: region)
        let session = ScrollCaptureSession(sampler: sampler)
        let hud = ScrollCaptureHUDController(session: session, region: region, automaticDriver: driver)
        hud.show(on: NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }))
        defer { hud.close() }
        var result: CGImage?
        hud.onFinish = { result = $0 }
        NSRunningApplication(processIdentifier: target.processIdentifier)?.activate(options: [])
        try await Task.sleep(for: .milliseconds(200))
        try await hud.start()
        // Retina matching processes four times as many pixels. Wait for an
        // accepted strip rather than finishing after a fixed wall-clock delay.
        for _ in 0..<150 {
            let progress = hud.window.contentView!.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
            if progress.contains(where: { $0.contains("已拼接") && !$0.contains("已拼接 1 段") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let advanced = try read()
        let labels = hud.window.contentView!.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        guard advanced["offset"]! > 0 else { throw Failure(message: "posted wheel events did not move the target; status=\(labels), target=\(target.processIdentifier), front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)") }
        let panelCapture = try await backend.captureWindow(id: CGWindowID(hud.window.windowNumber), includeCursor: false)
        try NSBitmapImageRep(cgImage: panelCapture.image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("automatic-panel.png"))
        func buttons(_ view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] } + view.subviews.flatMap { buttons($0) }
        }
        let controls = buttons(hud.window.contentView!)
        controls.first(where: { $0.title == "完成" })!.performClick(nil)
        for _ in 0..<30 {
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let expectedWidth = Int((region.width * mainScreen.backingScaleFactor).rounded())
        let expectedFrameHeight = Int((region.height * mainScreen.backingScaleFactor).rounded())
        guard let result, result.width == expectedWidth, result.height > expectedFrameHeight else {
            throw Failure(message: "no multi-frame long image; status=\(labels)")
        }
        let rep = NSBitmapImageRep(cgImage: result)
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            guard !(color.redComponent > 0.95 && color.greenComponent < 0.05 && color.blueComponent > 0.95) else {
                throw Failure(message: "Cutter-owned marker entered the screenshot")
            }
        } }
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("automatic-long.png"))
        let stopped = try read()["offset"]!
        try await Task.sleep(for: .milliseconds(800))
        guard try read()["offset"]! == stopped else { throw Failure(message: "target kept scrolling after completion") }
        print("Automatic desktop regression passed: real wheel events, ScreenCaptureKit, matching, HUD exclusion, completion; image=\(result.width)x\(result.height), target offset=\(stopped)")
    }

    private struct Failure: Error { let message: String }
}
