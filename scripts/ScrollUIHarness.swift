import AppKit
import CoreGraphics
import Foundation

actor MockSampler: ScrollFrameSampler {
    let image: CGImage
    private(set) var sampleCount = 0
    init(image: CGImage) { self.image = image }
    func sample() async throws -> CapturedImage {
        sampleCount += 1
        return CapturedImage(image: image, displayID: CGMainDisplayID(), scaleFactor: 1)
    }
    func cancel() async {}
}

@MainActor
final class ScrollUIHarness {
    let outputURL: URL
    init(outputURL: URL) { self.outputURL = outputURL }

    func run() async {
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let image = syntheticImage(width: 420, height: 1400)
        let sampler = MockSampler(image: image)
        let session = ScrollCaptureSession(sampler: sampler)
        let hud = ScrollCaptureHUDController(session: session, region: CGRect(x: 40, y: 120, width: 420, height: 300))
        NSApp.activate(ignoringOtherApps: true)
        hud.show(on: NSScreen.main)
        assert(!allButtons(in: hud.window).first(where: { $0.title == "完成" })!.isEnabled)
        do { try await hud.start() } catch { fatalError("HUD failed to start: \(error)") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        assert(hud.window.frame.width >= 380)
        assert(allButtons(in: hud.window).contains(where: { $0.title == "暂停" }))
        render(hud.window, named: "hud-initial.png")
        assert(allButtons(in: hud.window).first(where: { $0.title == "完成" })!.isEnabled)
        allButtons(in: hud.window).first(where: { $0.title == "暂停" })!.performClick(nil)
        try? await Task.sleep(for: .milliseconds(400))
        let pausedState = await session.state
        assert(pausedState == .paused)
        assert(allLabels(in: hud.window).contains(where: { $0.stringValue.contains("已暂停") }))
        hud.close()
        let stoppedCount = await sampler.sampleCount
        try? await Task.sleep(for: .milliseconds(400))
        let laterCount = await sampler.sampleCount
        assert(stoppedCount == laterCount, "closed HUD must not start another capture")

        let preview = LongImagePreviewController(image: image, scaleFactor: 1)
        var closeCount = 0
        preview.onClose = { closeCount += 1 }
        preview.show()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let scroll = allScrollViews(in: preview.window).first!
        assert(scroll.documentView!.bounds.height > scroll.contentView.bounds.height)
        let fitButton = allButtons(in: preview.window).first(where: { $0.title == "适合宽度" })!
        fitButton.performClick(nil)
        preview.window.contentView?.layoutSubtreeIfNeeded()
        assert(abs(scroll.documentView!.frame.width - (scroll.contentView.bounds.width - 4)) <= 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        render(preview.window, named: "preview-fit-top.png")
        assert(abs(scroll.contentView.bounds.minY - max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)) < 1)
        let actualButton = allButtons(in: preview.window).first(where: { $0.title == "100%" })!
        actualButton.performClick(nil)
        assert(scroll.documentView!.bounds.height >= CGFloat(image.height))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        assert(abs(scroll.contentView.bounds.origin.y) < 1, "nonflipped image bottom is y=0")
        render(preview.window, named: "preview-100-bottom.png")
        preview.window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 420), display: false)
        preview.window.contentView?.layoutSubtreeIfNeeded()
        assert(preview.window.frame.width >= 760)
        let controls = allButtons(in: preview.window)
        for (index, button) in controls.enumerated() {
            assert(preview.window.contentView!.bounds.contains(button.frame))
            if index + 1 < controls.count { for other in controls[(index + 1)...] { assert(!button.frame.intersects(other.frame)) } }
        }
        render(preview.window, named: "preview-resized.png")
        fitButton.performClick(nil)
        preview.window.setContentSize(CGSize(width: 900, height: 600))
        preview.window.contentView?.layoutSubtreeIfNeeded()
        assert(abs(scroll.documentView!.frame.width - (scroll.contentView.bounds.width - 4)) <= 1, "fit tracks window resize")
        allButtons(in: preview.window).first(where: { $0.title == "关闭" })!.performClick(nil)
        assert(closeCount == 1)

        let pin = PinnedImageWindowController(image: image, scaleFactor: 1)
        pin.show(); render(pin.window, named: "pin-long.png"); pin.close()
        let small = syntheticImage(width: 200, height: 120)
        let smallPin = PinnedImageWindowController(image: small, scaleFactor: 2)
        smallPin.show(); assert(smallPin.window.frame.width < 720); render(smallPin.window, named: "pin-normal.png"); smallPin.close()
        print("Scroll UI harness passed; PNGs: \(outputURL.path)")
        NSApp.terminate(nil)
    }

    private func allButtons(in window: NSWindow) -> [NSButton] {
        func walk(_ view: NSView) -> [NSButton] { view.subviews.flatMap { [$0 as? NSButton].compactMap { $0 } + walk($0) } }
        return walk(window.contentView ?? NSView())
    }
    private func allScrollViews(in window: NSWindow) -> [NSScrollView] {
        func walk(_ view: NSView) -> [NSScrollView] { view.subviews.flatMap { [$0 as? NSScrollView].compactMap { $0 } + walk($0) } }
        return walk(window.contentView ?? NSView())
    }
    private func allLabels(in window: NSWindow) -> [NSTextField] {
        func walk(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { [$0 as? NSTextField].compactMap { $0 } + walk($0) } }
        return walk(window.contentView ?? NSView())
    }
    private func render(_ window: NSWindow, named name: String) {
        window.displayIfNeeded()
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("cannot create bitmap representation") }
        view.layoutSubtreeIfNeeded()
        view.display()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode PNG") }
        do { try data.write(to: outputURL.appendingPathComponent(name)) } catch { fatalError("cannot write PNG: \(error)") }
    }
    private func syntheticImage(width: Int, height: Int) -> CGImage {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 40) { c.setFillColor(NSColor(calibratedRed: CGFloat(y % 255) / 255, green: 0.35, blue: 0.65, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: y, width: width, height: 20)) }
        return c.makeImage()!
    }
}

@main
struct ScrollUIHarnessMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/scroll-ui-tests")
        Task { @MainActor in await ScrollUIHarness(outputURL: output).run() }
        app.run()
    }
}
