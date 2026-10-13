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
final class MockScrollDriver: AutomaticScrollDriving {
    var scrollCount = 0
    var failure: AutomaticScrollError?
    var permissionRequests = 0
    var onScroll: (() -> Void)?
    func prepare() throws { if let failure { throw failure } }
    func scrollDown(points: Int32) throws {
        try prepare()
        assert(points > 0 && points <= 120)
        scrollCount += 1
        onScroll?()
    }
    func requestPermission() { permissionRequests += 1 }
    func stop() {}
}

@MainActor
final class ScrollingFixtureSampler: ScrollFrameSampler {
    let source: CGImage
    var offset = 0
    var sampleCount = 0
    init(source: CGImage) { self.source = source }
    func sample() async throws -> CapturedImage {
        sampleCount += 1
        return CapturedImage(image: source.cropping(to: CGRect(x: 0, y: offset, width: 96, height: 96))!, displayID: 1, scaleFactor: 1)
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

        testAutomaticPacer()
        await testAutomaticHUD()

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

    private func testAutomaticPacer() {
        var pacer = AutomaticScrollPacer()
        assert(pacer.next(for: .ready, now: 0) == .scroll)
        pacer.didScroll(at: 0)
        assert(pacer.next(for: .waitingForStableFrame, now: 0.32) == .wait)
        assert(pacer.next(for: .duplicate, now: 1) == .wait)
        assert(pacer.next(for: .duplicate, now: 2) == .scroll)
        pacer.didScroll(at: 2)
        assert(pacer.next(for: .duplicate, now: 4) == .scroll)
        pacer.didScroll(at: 4)
        guard case .pause = pacer.next(for: .duplicate, now: 6) else { fatalError("unchanged content must pause") }
        pacer.reset()
        assert(pacer.next(for: .duplicate, now: 7) == .scroll, "resume can restart from an unchanged baseline")
        pacer.didScroll(at: 7)
        guard case .pause = pacer.next(for: .waitingForStableFrame, now: 15) else { fatalError("unstable content must time out") }
        pacer.reset()
        assert(pacer.next(for: .waitingForStableFrame, now: 20) == .wait)
        guard case .pause = pacer.next(for: .waitingForStableFrame, now: 28) else { fatalError("resume instability must time out") }
        for outcome: ScrollCaptureSession.FrameOutcome in [.reverse, .ambiguous, .insufficientOverlap, .lowTexture] {
            guard case .pause = pacer.next(for: outcome, now: 30) else { fatalError("unreliable match must stop input") }
        }
        pacer.reset()
        assert(pacer.next(for: .accepted(addedHeight: 20, totalHeight: 116, segmentCount: 2), now: 31) == .scroll)
    }

    private func testAutomaticHUD() async {
        // Real session + deterministic scrolling content, with fake event egress.
        let context = CGContext(data: nil, width: 96, height: 500, bitsPerComponent: 8, bytesPerRow: 384, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<500 { for x in 0..<96 {
            let i = (y * 96 + x) * 4
            let v = UInt8((x * 17 + y * 29 + ((x / 7 + y / 5) % 2) * 61) & 255)
            bytes[i] = v; bytes[i + 1] = v ^ 0x35; bytes[i + 2] = v ^ 0x7a; bytes[i + 3] = 255
        } }
        let sampler = ScrollingFixtureSampler(source: context.makeImage()!)
        let driver = MockScrollDriver()
        driver.onScroll = { sampler.offset = min(400, sampler.offset + 20) }
        let session = ScrollCaptureSession(sampler: sampler)
        let hud = ScrollCaptureHUDController(session: session, region: CGRect(x: 40, y: 120, width: 420, height: 300), automaticDriver: driver)
        hud.show()
        do { try await hud.start() } catch { fatalError("auto start failed: \(error)") }
        assert(driver.scrollCount == 1)
        await waitUntil { driver.scrollCount >= 2 }
        assert(driver.scrollCount >= 2, "successful stitching drives another step")
        let pause = allButtons(in: hud.window).first(where: { $0.title == "暂停" })!
        pause.performClick(nil)
        try? await Task.sleep(for: .milliseconds(100))
        let count = driver.scrollCount
        try? await Task.sleep(for: .milliseconds(800))
        assert(count == driver.scrollCount, "pause stops automatic input")
        pause.performClick(nil)
        await waitUntil { driver.scrollCount > count }
        assert(driver.scrollCount > count, "resume observes then scrolls")
        driver.failure = .targetChanged
        try? await Task.sleep(for: .milliseconds(800))
        let state = await session.state
        assert(state == .paused)
        assert(allLabels(in: hud.window).contains(where: { $0.stringValue.contains("目标窗口") }))
        render(hud.window, named: "hud-auto-paused.png")
        var outputs = 0
        hud.onFinish = { _ in outputs += 1 }
        allButtons(in: hud.window).first(where: { $0.title == "完成" })!.performClick(nil)
        try? await Task.sleep(for: .milliseconds(200))
        assert(outputs == 1)
        let finishedCount = driver.scrollCount
        try? await Task.sleep(for: .milliseconds(400))
        assert(driver.scrollCount == finishedCount)
        hud.close()

        let deniedDriver = MockScrollDriver()
        deniedDriver.failure = .permissionRequired
        let deniedSession = ScrollCaptureSession(sampler: MockSampler(image: syntheticImage(width: 96, height: 96)))
        let deniedHUD = ScrollCaptureHUDController(session: deniedSession, region: .zero, automaticDriver: deniedDriver)
        deniedHUD.show()
        do { try await deniedHUD.start() } catch { fatalError("denied HUD failed: \(error)") }
        assert(deniedDriver.scrollCount == 0)
        let permission = allButtons(in: deniedHUD.window).first(where: { $0.title == "授权…" })!
        assert(!permission.isHidden)
        permission.performClick(nil)
        assert(deniedDriver.permissionRequests == 1)
        let modes = deniedHUD.window.contentView!.subviews.compactMap { $0 as? NSSegmentedControl }.first!
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action!, to: modes.target)
        try? await Task.sleep(for: .milliseconds(100))
        allButtons(in: deniedHUD.window).first(where: { $0.title == "继续" })!.performClick(nil)
        try? await Task.sleep(for: .milliseconds(800))
        assert(deniedDriver.scrollCount == 0, "manual fallback never sends input")
        let manualState = await deniedSession.state
        assert(manualState == .capturing)
        deniedHUD.close()
        try? await Task.sleep(for: .milliseconds(400))
        assert(deniedDriver.scrollCount == 0)
        print("Automatic scroll regression passed: pacing, matched advance, pause/resume, target change, finish, permission/manual fallback")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
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
