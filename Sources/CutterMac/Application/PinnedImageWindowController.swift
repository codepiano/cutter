import AppKit

@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    var onClose: (() -> Void)?

    init(image: CGImage, scaleFactor: CGFloat) {
        let pointSize = CGSize(
            width: max(160, CGFloat(image.width) / max(1, scaleFactor)),
            height: max(120, CGFloat(image.height) / max(1, scaleFactor))
        )
        let maxSize = CGSize(width: 720, height: 540)
        let scale = min(1, min(maxSize.width / pointSize.width, maxSize.height / pointSize.height))
        let contentSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        window = NSPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let imageView = NSImageView(frame: CGRect(origin: .zero, size: contentSize))
        imageView.image = NSImage(cgImage: image, size: pointSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.setAccessibilityLabel("临时贴图内容")
        imageView.autoresizingMask = [.width, .height]

        window.title = "临时贴图（不保存）"
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = imageView
        window.setAccessibilityLabel("临时贴图，不保存")
        window.setAccessibilityHelp("只在浮动窗口中临时显示，不会保存到文件；关闭窗口后移除")
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
