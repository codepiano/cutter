import AppKit

final class ScrollRegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
    }
}

@MainActor
final class ScrollCaptureHUDController: NSObject, NSWindowDelegate {
    private let session: ScrollCaptureSession
    private let region: CGRect
    private var timer: Timer?
    private var ended = false
    private var finishing = false
    private var paused = false
    private var sampling = false
    private var transitioning = false
    private var revision: UInt64 = 0
    private let automaticDriver: (any AutomaticScrollDriving)?
    private var automatic: Bool
    private var pacer = AutomaticScrollPacer()
    private let modeControl = NSSegmentedControl(labels: ["自动滚动", "手动滚动"], trackingMode: .selectOne, target: nil, action: nil)
    private let permissionButton = NSButton(title: "授权…", target: nil, action: nil)
    let window: NSPanel
    private let status = NSTextField(labelWithString: "准备首屏…")
    private let progress = NSTextField(labelWithString: "")
    private let thumbnail = NSImageView()
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let undoButton = NSButton(title: "撤销末段", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    init(session: ScrollCaptureSession, region: CGRect, automaticDriver: (any AutomaticScrollDriving)? = nil) {
        self.session = session
        self.region = region
        self.automaticDriver = automaticDriver
        automatic = automaticDriver != nil
        window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 220), styleMask: [.titled, .nonactivatingPanel, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "滚动截图"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        modeControl.selectedSegment = automatic ? 0 : 1
        modeControl.setEnabled(automaticDriver != nil, forSegment: 0)
        modeControl.target = self
        modeControl.action = #selector(changeMode)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.setAccessibilityLabel("滚动方式")
        content.addSubview(modeControl)
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        permissionButton.isHidden = true
        permissionButton.setAccessibilityLabel("授权自动滚动")
        content.addSubview(permissionButton)
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progress.textColor = .secondaryLabelColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.imageFrameStyle = .grayBezel
        thumbnail.setAccessibilityLabel("最新接缝缩略图")
        content.addSubview(thumbnail)
        for label in [status, progress] { label.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(label) }
        let buttons = [pauseButton, undoButton, finishButton, cancelButton]
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.target = self
            content.addSubview(button)
        }
        pauseButton.action = #selector(togglePause)
        undoButton.action = #selector(undo)
        finishButton.action = #selector(finish)
        cancelButton.action = #selector(cancelCapture)
        finishButton.isEnabled = false
        undoButton.isEnabled = false
        pauseButton.isEnabled = false
        finishButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        pauseButton.setAccessibilityLabel("暂停或继续滚动截图")
        undoButton.setAccessibilityLabel("撤销末段")
        finishButton.setAccessibilityLabel("完成滚动截图")
        cancelButton.setAccessibilityLabel("取消滚动截图")
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), modeControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            permissionButton.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 12), permissionButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), status.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12), status.heightAnchor.constraint(equalToConstant: 40),
            progress.leadingAnchor.constraint(equalTo: status.leadingAnchor), progress.trailingAnchor.constraint(equalTo: status.trailingAnchor), progress.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            thumbnail.leadingAnchor.constraint(equalTo: status.leadingAnchor), thumbnail.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8), thumbnail.widthAnchor.constraint(equalToConstant: 70), thumbnail.heightAnchor.constraint(equalToConstant: 42),
            pauseButton.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10), pauseButton.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 7),
            undoButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 6), undoButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            finishButton.leadingAnchor.constraint(equalTo: undoButton.trailingAnchor, constant: 6), finishButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: finishButton.trailingAnchor, constant: 6), cancelButton.trailingAnchor.constraint(lessThanOrEqualTo: status.trailingAnchor), cancelButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor)
        ])
        window.contentView = content
        window.setAccessibilityLabel("滚动截图控制面板")
    }

    func show(on screen: NSScreen? = NSScreen.main) {
        guard let screen else { window.center(); window.orderFrontRegardless(); return }
        let frame = screen.visibleFrame
        let globalRegion = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.minY + region.minY, width: region.width, height: region.height)
        let candidates = [
            CGPoint(x: globalRegion.minX, y: globalRegion.minY - window.frame.height - 14),
            CGPoint(x: globalRegion.minX, y: globalRegion.maxY + 14),
            CGPoint(x: globalRegion.maxX + 14, y: globalRegion.maxY - window.frame.height),
            CGPoint(x: globalRegion.minX - window.frame.width - 14, y: globalRegion.maxY - window.frame.height)
        ]
        let origin = candidates.first(where: { NSRect(origin: $0, size: window.frame.size).intersects(frame) && frame.contains(NSRect(origin: $0, size: window.frame.size)) }) ?? CGPoint(x: frame.maxX - window.frame.width - 12, y: frame.maxY - window.frame.height - 12)
        window.setFrameOrigin(origin); window.orderFrontRegardless()
    }

    func start() async throws {
        let snapshot = try await session.start()
        guard !ended, !finishing else { return }
        apply(snapshot)
        await updateThumbnail()
        guard !ended, !finishing else { return }
        if automatic { await drive(.ready) }
        guard !ended, !finishing else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.sample() }
        }
    }

    private func sample() async {
        guard !ended, !finishing, !paused, !sampling, !transitioning else { return }
        sampling = true
        defer { sampling = false }
        let token = revision
        if automatic {
            do { try automaticDriver?.prepare() }
            catch { await pauseAutomatic(error); return }
        }
        let snapshot = await session.captureNext()
        guard !ended, !finishing, !paused, token == revision else { return }
        if automatic {
            do { try automaticDriver?.prepare() }
            catch {
                // If the target changed during the async capture, discard the
                // newly appended strip before exposing or exporting it.
                if case .accepted = snapshot.outcome { apply(await session.undoLast()) }
                await pauseAutomatic(error)
                return
            }
        }
        apply(snapshot)
        if case .accepted = snapshot.outcome { await updateThumbnail() }
        guard !ended, !finishing, !paused, token == revision else { return }
        if automatic { await drive(snapshot.outcome) }
    }

    private func apply(_ snapshot: ScrollCaptureSession.Snapshot) {
        guard !ended, !finishing else { return }
        paused = snapshot.state == .paused
        if paused { automaticDriver?.stop() }
        progress.stringValue = snapshot.width > 0 ? "\(snapshot.width) × \(snapshot.height) px · 已拼接 \(snapshot.segmentCount) 段" : ""
        switch snapshot.outcome {
        case .ready: status.stringValue = paused ? "已暂停，可拖动面板；点击继续恢复" : (automatic ? "自动滚动中 · 移开鼠标可暂停 · 选区避开固定页头/页脚" : "在框内向下滚动一小段，稍停后继续 · 选区避开固定页头/页脚")
        case .accepted: status.stringValue = automatic ? "已拼接一段，继续自动滚动" : "已接收一段，继续缓慢向下滚动"
        case .duplicate: status.stringValue = automatic ? "等待内容变化，稍后重试…" : "等待向下滚动"
        case .reverse: status.stringValue = "请继续向下滚动"
        case .waitingForStableFrame: status.stringValue = "等待画面稳定…"
        case .insufficientOverlap, .ambiguous, .lowTexture: status.stringValue = "暂时无法衔接，往回滚一点后慢慢继续"
        case .dimensionsChanged: status.stringValue = "捕获区域变化，已有结果仍可完成"
        case .captureFailed: status.stringValue = "采样失败，已有结果仍可完成"
        case .tooLarge: status.stringValue = "已达到本次长图上限，可完成保存"
        }
        undoButton.isEnabled = snapshot.canUndo
        pauseButton.isEnabled = true
        finishButton.isEnabled = snapshot.height > 0 && !ended
        if snapshot.state == .paused { pauseButton.title = "继续" }
        else if snapshot.state != .finishing { pauseButton.title = "暂停" }
    }

    @objc private func togglePause() {
        guard !ended, !finishing, !transitioning else { return }
        let isPaused = paused
        revision &+= 1
        paused = true
        transitioning = true
        if !isPaused { automaticDriver?.stop() }
        Task {
            defer { transitioning = false }
            if isPaused {
                // Revalidate permission and the original target before resuming.
                if automatic {
                    do { try automaticDriver?.prepare() }
                    catch { await pauseAutomatic(error); return }
                }
                await session.resume()
                guard !ended, !finishing else { return }
                paused = false
                pacer.reset()
                pauseButton.title = "暂停"
                status.stringValue = automatic ? "恢复采样，等待画面稳定…" : "在框内向下滚动一小段，稍停后继续"
            } else {
                await session.pause()
                guard !ended, !finishing else { return }
                pauseButton.title = "继续"
                status.stringValue = "已暂停，可拖动面板；点击继续恢复"
            }
        }
    }

    @objc private func changeMode() {
        guard !ended, !finishing, !transitioning else {
            modeControl.selectedSegment = automatic ? 0 : 1
            return
        }
        revision &+= 1
        automatic = modeControl.selectedSegment == 0
        automaticDriver?.stop()
        permissionButton.isHidden = true
        pacer.reset()
        // Switching mode is deliberately paused; Continue observes the current
        // frame before sending input, preserving any content already scrolled.
        paused = true
        transitioning = true
        Task {
            defer { transitioning = false }
            await session.pause()
            guard !ended, !finishing else { return }
            pauseButton.title = "继续"
            status.stringValue = automatic ? "已切换自动模式；恢复目标窗口后点击继续" : "已切换手动模式；点击继续后在框内滚动"
        }
    }

    @objc private func requestPermission() {
        guard !ended, !finishing else { return }
        automaticDriver?.requestPermission()
        status.stringValue = "在系统设置中允许 Cutter 的辅助功能权限；返回目标窗口后点击继续"
    }

    private func drive(_ outcome: ScrollCaptureSession.FrameOutcome) async {
        guard automatic, !ended, !finishing, !paused, let automaticDriver else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch pacer.next(for: outcome, now: now) {
        case .wait: break
        case .scroll:
            do {
                try automaticDriver.scrollDown(points: Int32(max(16, min(120, region.height * 0.2))))
                pacer.didScroll(at: now)
            } catch { await pauseAutomatic(error) }
        case .pause(let reason): await pauseAutomatic(reason: reason)
        }
    }

    private func pauseAutomatic(_ error: any Error) async {
        permissionButton.isHidden = (error as? AutomaticScrollError) != .permissionRequired
        await pauseAutomatic(reason: error.localizedDescription)
    }

    private func pauseAutomatic(reason: String) async {
        paused = true
        automaticDriver?.stop()
        revision &+= 1
        await session.pause()
        guard !ended, !finishing else { return }
        pauseButton.title = "继续"
        status.stringValue = reason
    }
    @objc private func undo() {
        guard !ended, !finishing, !transitioning else { return }
        revision &+= 1
        paused = true
        automaticDriver?.stop()
        transitioning = true
        Task {
            defer { transitioning = false }
            await session.pause()
            apply(await session.undoLast())
            guard !ended, !finishing else { return }
            status.stringValue = "已撤销末段；往回滚到上一段后继续"
            await updateThumbnail()
        }
    }
    private func updateThumbnail() async {
        let image = await session.seamThumbnail(maxWidth: 320, tailHeight: 192)
        guard !ended, !finishing, let image else { return }
        thumbnail.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }
    @objc private func finish() {
        guard !ended, !finishing, finishButton.isEnabled else { return }
        finishing = true
        automaticDriver?.stop()
        revision &+= 1
        modeControl.isEnabled = false
        permissionButton.isEnabled = false
        timer?.invalidate(); timer = nil
        finishButton.isEnabled = false
        pauseButton.isEnabled = false
        undoButton.isEnabled = false
        status.stringValue = "正在生成长图…"
        Task {
            let image = await session.finish()
            guard !ended else { return }
            ended = true
            if let image { onFinish?(image) } else { onCancel?() }
        }
    }
    @objc private func cancelCapture() { guard !ended else { return }; ended = true; automaticDriver?.stop(); timer?.invalidate(); timer = nil; Task { await session.cancel(); onCancel?() } }
    func cancel() {
        ended = true
        automaticDriver?.stop()
        timer?.invalidate(); timer = nil
        Task { await session.cancel() }
    }
    func close() { cancel(); window.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { cancelCapture() }
}
