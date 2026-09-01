import AppKit
import CoreGraphics

@MainActor
final class CaptureCountdownController {
    private let panel: NSPanel
    private let countLabel = NSTextField(labelWithString: "")

    init() {
        let size = CGSize(width: 156, height: 116)
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        content.layer?.cornerRadius = 18
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel("截图倒计时")

        countLabel.frame = CGRect(x: 12, y: 40, width: size.width - 24, height: 62)
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        countLabel.textColor = .white
        countLabel.alignment = .center
        countLabel.setAccessibilityLabel("剩余秒数")
        content.addSubview(countLabel)

        let hint = NSTextField(labelWithString: "再次按 ⌥⌘2 取消")
        hint.frame = CGRect(x: 8, y: 16, width: size.width - 16, height: 18)
        hint.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.72)
        hint.alignment = .center
        content.addSubview(hint)

        panel.contentView = content
    }

    func run(
        seconds: Int,
        tickNanoseconds: UInt64 = 1_000_000_000,
        onTick: @escaping @MainActor (Int) -> Void
    ) async throws {
        guard seconds > 0 else { return }
        show()
        defer { hide() }

        for remaining in stride(from: seconds, through: 1, by: -1) {
            try Task.checkCancellation()
            countLabel.stringValue = "\(remaining)"
            countLabel.setAccessibilityValue("\(remaining) 秒")
            onTick(remaining)
            try await Task.sleep(nanoseconds: tickNanoseconds)
        }
        onTick(0)
    }

    func cancel() {
        hide()
    }

    private func show() {
        let targetScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == CGMainDisplayID()
        }) ?? NSScreen.main
        if let frame = targetScreen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            ))
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel.orderOut(nil)
    }
}
