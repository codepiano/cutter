import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureBackend: any ScreenCaptureBackend
    private let shortcutService = GlobalShortcutService()
    private var statusItem: NSStatusItem?
    private var selectionController: RegionSelectionController?
    private var countdownController: CaptureCountdownController?
    private var captureTask: Task<Void, Never>?
    private var pinnedWindows: [PinnedImageWindowController] = []
    private var captureSettings = CaptureSettings.current
    private var includeCursorItem: NSMenuItem?
    private var captureItem: NSMenuItem?
    private var delayItems: [Int: NSMenuItem] = [:]
    private var closeAllPinsItem: NSMenuItem?
    private var isCapturing = false

    override init() {
        self.captureBackend = ScreenCaptureKitBackend()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        do {
            try shortcutService.registerDefault { [weak self] in
                self?.capturePrimaryDisplay()
            }
        } catch {
            present(error: error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureTask?.cancel()
        countdownController?.cancel()
        selectionController?.cancel()
        shortcutService.unregister()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: "Cutter"
        )
        item.button?.toolTip = "Cutter（快捷键：⌥⌘2）"

        let menu = NSMenu()
        let captureItem = menu.addItem(
            withTitle: "开始截图    ⌥⌘2",
            action: #selector(capturePrimaryDisplay),
            keyEquivalent: ""
        )
        captureItem.target = self
        self.captureItem = captureItem

        let modeMenu = NSMenu()
        let regionItem = modeMenu.addItem(withTitle: "智能窗口与区域截图", action: nil, keyEquivalent: "")
        regionItem.state = .on
        let fullScreenItem = modeMenu.addItem(withTitle: "全屏截图（即将支持）", action: nil, keyEquivalent: "")
        fullScreenItem.isEnabled = false
        let modeItem = menu.addItem(withTitle: "截图方式", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu

        let delayMenu = NSMenu()
        for delay in CaptureSettings.Delay.allCases {
            let delayItem = delayMenu.addItem(
                withTitle: delay.title,
                action: #selector(selectCaptureDelay(_:)),
                keyEquivalent: ""
            )
            delayItem.target = self
            delayItem.tag = delay.rawValue
            delayItem.state = delay == captureSettings.delay ? .on : .off
            delayItems[delay.rawValue] = delayItem
        }
        let delayItem = menu.addItem(withTitle: "截图延时", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu

        let cursorItem = menu.addItem(
            withTitle: "包含鼠标指针",
            action: #selector(toggleCursor),
            keyEquivalent: ""
        )
        cursorItem.target = self
        cursorItem.state = captureSettings.includeCursor ? .on : .off
        includeCursorItem = cursorItem

        let permissionItem = menu.addItem(
            withTitle: "检查截图权限",
            action: #selector(checkPermission),
            keyEquivalent: ""
        )
        permissionItem.target = self

        let closePinsItem = menu.addItem(
            withTitle: "关闭所有临时贴图",
            action: #selector(closeAllPinnedImages),
            keyEquivalent: ""
        )
        closePinsItem.target = self
        closePinsItem.isEnabled = false
        closeAllPinsItem = closePinsItem

        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: "退出 Cutter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleCursor() {
        captureSettings.includeCursor.toggle()
        includeCursorItem?.state = captureSettings.includeCursor ? .on : .off
        captureSettings.persist()
    }

    @objc private func selectCaptureDelay(_ sender: NSMenuItem) {
        guard let delay = CaptureSettings.Delay(rawValue: sender.tag) else { return }
        captureSettings.delay = delay
        captureSettings.persist()
        for (seconds, item) in delayItems {
            item.state = seconds == delay.rawValue ? .on : .off
        }
    }

    @objc private func capturePrimaryDisplay() {
        if countdownController != nil {
            cancelDelayedCapture()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true

        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishCaptureTask() }
            do {
                if self.captureSettings.delay.rawValue > 0 {
                    let countdown = CaptureCountdownController()
                    self.countdownController = countdown
                    self.captureItem?.title = "取消延时截图    ⌥⌘2"
                    try await countdown.run(seconds: self.captureSettings.delay.rawValue) { [weak self] remaining in
                        self?.showCountdownStatus(remaining: remaining)
                    }
                    self.countdownController = nil
                    self.restoreIdleStatus()
                    try await Task.sleep(nanoseconds: 120_000_000)
                }
                try Task.checkCancellation()
                try await self.performRegionCapture()
            } catch is CancellationError {
                self.restoreIdleStatus()
            } catch {
                self.present(error: error)
            }
        }
    }

    private func performRegionCapture() async throws {
        let workspace = try await captureBackend.preparePrimaryDisplay(
            includeCursor: captureSettings.includeCursor
        )
        let includeCursor = captureSettings.includeCursor
        let backend = captureBackend
        let controller = RegionSelectionController()
        selectionController = controller
        guard let result = await controller.selectRegion(
            from: workspace.display,
            defaultOutput: captureSettings.output,
            windows: workspace.windows,
            windowCaptureProvider: { windowID in
                try await backend.captureWindow(id: windowID, includeCursor: includeCursor)
            },
            scrollSamplerProvider: { displayID, region in
                try await backend.prepareScrollSampler(
                    displayID: displayID,
                    region: region,
                    includeCursor: false
                )
            }
        ) else {
            selectionController = nil
            return
        }
        selectionController = nil
        captureSettings.output = result.output
        captureSettings.persist()
        switch result.output {
        case .copy:
            try ImageClipboard.copy(result.image, scaleFactor: workspace.display.scaleFactor)
        case .save:
            _ = try ImageFileWriter.savePNG(
                result.image,
                to: captureSettings.downloadDirectory
            )
        case .copyAndSave:
            try ImageClipboard.copy(result.image, scaleFactor: workspace.display.scaleFactor)
            _ = try ImageFileWriter.savePNG(
                result.image,
                to: captureSettings.downloadDirectory
            )
        case .pin:
            showPinnedImage(result.image, scaleFactor: workspace.display.scaleFactor)
        }
        showStatusFeedback(for: result.output)
    }

    private func cancelDelayedCapture() {
        captureTask?.cancel()
        countdownController?.cancel()
        countdownController = nil
        restoreIdleStatus()
    }

    private func finishCaptureTask() {
        countdownController?.cancel()
        countdownController = nil
        captureTask = nil
        isCapturing = false
        captureItem?.title = "开始截图    ⌥⌘2"
    }

    private func showCountdownStatus(remaining: Int) {
        guard remaining > 0 else { return }
        let description = "截图将在 \(remaining) 秒后开始"
        statusItem?.button?.image = NSImage(
            systemSymbolName: "timer",
            accessibilityDescription: description
        )
        statusItem?.button?.toolTip = "\(description)；再次按 ⌥⌘2 取消"
    }

    private func restoreIdleStatus() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: "Cutter"
        )
        statusItem?.button?.toolTip = "Cutter（快捷键：⌥⌘2）"
        captureItem?.title = "开始截图    ⌥⌘2"
    }

    private func showPinnedImage(_ image: CGImage, scaleFactor: CGFloat) {
        let controller = PinnedImageWindowController(image: image, scaleFactor: scaleFactor)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.pinnedWindows.removeAll { $0 === controller }
            self.closeAllPinsItem?.isEnabled = !self.pinnedWindows.isEmpty
        }
        pinnedWindows.append(controller)
        closeAllPinsItem?.isEnabled = true
        controller.show()
    }

    @objc private func closeAllPinnedImages() {
        pinnedWindows.forEach { $0.close() }
        pinnedWindows.removeAll()
        closeAllPinsItem?.isEnabled = false
    }

    @objc private func checkPermission() {
        if ScreenCapturePermission.isGranted {
            let alert = NSAlert()
            alert.messageText = "截图权限已开启"
            alert.informativeText = "Cutter 可以读取屏幕内容。"
            alert.runModal()
            return
        }

        if !ScreenCapturePermission.request() {
            present(error: ScreenCaptureError.permissionDenied)
        }
    }

    private func showStatusFeedback(for output: CaptureSettings.Output) {
        let description: String
        switch output {
        case .copy: description = "截图已复制"
        case .save: description = "截图已存储"
        case .copyAndSave: description = "截图已复制并存储"
        case .pin: description = "临时贴图已打开"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: description
        )
        statusItem?.button?.toolTip = description

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem?.button?.image = NSImage(
                systemSymbolName: "viewfinder",
                accessibilityDescription: "Cutter"
            )
            self?.statusItem?.button?.toolTip = "Cutter（快捷键：⌥⌘2）"
        }
    }

    private func present(error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
