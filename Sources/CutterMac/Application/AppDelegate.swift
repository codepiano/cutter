import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureBackend: any ScreenCaptureBackend
    private let shortcutService = GlobalShortcutService()
    private var statusItem: NSStatusItem?
    private var selectionController: RegionSelectionController?
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
            withTitle: "截取区域并复制    ⌥⌘2",
            action: #selector(capturePrimaryDisplay),
            keyEquivalent: ""
        )
        captureItem.target = self

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

    @objc private func capturePrimaryDisplay() {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }
            do {
                let capture = try await captureBackend.capturePrimaryDisplay()
                let controller = RegionSelectionController()
                selectionController = controller
                guard let image = await controller.selectRegion(from: capture) else {
                    selectionController = nil
                    return
                }
                selectionController = nil
                try ImageClipboard.copy(image, scaleFactor: capture.scaleFactor)
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
