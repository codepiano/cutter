import AppKit

@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    var onClose: (() -> Void)?

    init(image: CGImage, scaleFactor: CGFloat) {
        let pointSize = CGSize(
            width: max(1, CGFloat(image.width) / max(1, scaleFactor)),
            height: max(1, CGFloat(image.height) / max(1, scaleFactor))
        )
        let isLongImage = pointSize.height > pointSize.width * 1.5
        let maxSize = CGSize(width: 720, height: 540)
        let scale = isLongImage ? 1 : min(1, min(maxSize.width / pointSize.width, maxSize.height / pointSize.height))
        let contentSize = isLongImage
            ? CGSize(width: min(860, max(420, pointSize.width)), height: 700)
            : CGSize(width: max(160, pointSize.width * scale), height: max(120, pointSize.height * scale))
        window = NSPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let imageView = NSImageView(frame: CGRect(origin: .zero, size: CGSize(width: pointSize.width * scale, height: pointSize.height * scale)))
        imageView.image = NSImage(cgImage: image, size: pointSize)
        imageView.imageScaling = isLongImage ? .scaleNone : .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.setAccessibilityLabel("临时贴图内容")
        if isLongImage {
            let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: contentSize))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autoresizingMask = [.width, .height]
            scrollView.documentView = imageView
            window.contentView = scrollView
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: max(0, imageView.frame.height - scrollView.contentSize.height)))
        } else {
            imageView.frame = CGRect(origin: .zero, size: contentSize)
            imageView.autoresizingMask = [.width, .height]
            window.contentView = imageView
        }

        window.title = "临时贴图（不保存）"
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.delegate = self
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
