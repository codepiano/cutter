import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureBackend: any ScreenCaptureBackend
    private let shortcutService = GlobalShortcutService()
    private var statusItem: NSStatusItem?
    private var selectionController: RegionSelectionController?
    private var captureSettings = CaptureSettings.current
    private var includeCursorItem: NSMenuItem?
    private var outputItems: [CaptureSettings.Output: NSMenuItem] = [:]
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
                self?.openCaptureMenu()
            }
        } catch {
            present(error: error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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

        let modeMenu = NSMenu()
        let regionItem = modeMenu.addItem(withTitle: "区域截图", action: nil, keyEquivalent: "")
        regionItem.state = .on
        let windowItem = modeMenu.addItem(withTitle: "窗口截图（即将支持）", action: nil, keyEquivalent: "")
        windowItem.isEnabled = false
        let fullScreenItem = modeMenu.addItem(withTitle: "全屏截图（即将支持）", action: nil, keyEquivalent: "")
        fullScreenItem.isEnabled = false
        let modeItem = menu.addItem(withTitle: "截图方式", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu

        let cursorItem = menu.addItem(
            withTitle: "包含鼠标指针",
            action: #selector(toggleCursor),
            keyEquivalent: ""
        )
        cursorItem.target = self
        cursorItem.state = captureSettings.includeCursor ? .on : .off
        includeCursorItem = cursorItem

        let outputMenu = NSMenu()
        addOutputItem(to: outputMenu, title: "复制到剪贴板", output: .copy)
        addOutputItem(to: outputMenu, title: "保存为 PNG", output: .save)
        addOutputItem(to: outputMenu, title: "复制并保存", output: .copyAndSave)
        let outputItem = menu.addItem(withTitle: "截图后操作", action: nil, keyEquivalent: "")
        outputItem.submenu = outputMenu

        let permissionItem = menu.addItem(
            withTitle: "检查截图权限",
            action: #selector(checkPermission),
            keyEquivalent: ""
        )
        permissionItem.target = self

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

    private func addOutputItem(to menu: NSMenu, title: String, output: CaptureSettings.Output) {
        let item = menu.addItem(
            withTitle: title,
            action: #selector(selectOutput(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = output.rawValue
        item.state = captureSettings.output == output ? .on : .off
        outputItems[output] = item
    }

    @objc private func openCaptureMenu() {
        statusItem?.button?.performClick(nil)
    }

    @objc private func toggleCursor() {
        captureSettings.includeCursor.toggle()
        includeCursorItem?.state = captureSettings.includeCursor ? .on : .off
        captureSettings.persist()
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let output = CaptureSettings.Output(rawValue: rawValue) else { return }
        captureSettings.output = output
        for (candidate, item) in outputItems {
            item.state = candidate == output ? .on : .off
        }
        captureSettings.persist()
    }

    @objc private func capturePrimaryDisplay() {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }
            do {
                let capture = try await captureBackend.capturePrimaryDisplay(
                    includeCursor: captureSettings.includeCursor
                )
                let controller = RegionSelectionController()
                selectionController = controller
                guard let image = await controller.selectRegion(from: capture) else {
                    selectionController = nil
                    return
                }
                selectionController = nil
                switch captureSettings.output {
                case .copy:
                    try ImageClipboard.copy(image, scaleFactor: capture.scaleFactor)
                case .save:
                    try ImageFileWriter.savePNG(image)
                case .copyAndSave:
                    try ImageClipboard.copy(image, scaleFactor: capture.scaleFactor)
                    try ImageFileWriter.savePNG(image)
                }
                showStatusFeedback()
            } catch {
                present(error: error)
            }
        }
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

    private func showStatusFeedback() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "截图已复制"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem?.button?.image = NSImage(
                systemSymbolName: "viewfinder",
                accessibilityDescription: "Cutter"
            )
        }
    }

    private func present(error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
