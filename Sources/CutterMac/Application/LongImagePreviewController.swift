import AppKit

@MainActor
final class LongImagePreviewController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let image: CGImage
    private let scaleFactor: CGFloat
    private weak var previewScroll: NSScrollView?
    private weak var previewImageView: NSImageView?
    private var fitsWidth = true
    private var ended = false
    var onOutput: ((CGImage, CaptureSettings.Output) -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage, scaleFactor: CGFloat) {
        self.image = image; self.scaleFactor = max(1, scaleFactor)
        let size = CGSize(width: min(980, max(760, CGFloat(image.width) / self.scaleFactor + 40)), height: 720)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "长图预览 · \(image.width) × \(image.height) px"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 760, height: 420)
        let root = NSView(frame: CGRect(origin: .zero, size: size)); root.autoresizingMask = [.width, .height]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 84, width: size.width, height: size.height - 84))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = false; scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        let imageView = NSImageView(image: NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / self.scaleFactor, height: CGFloat(image.height) / self.scaleFactor)))
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.imageAlignment = .alignCenter; imageView.setAccessibilityLabel("长图内容")
        scroll.documentView = imageView; root.addSubview(scroll)
        previewScroll = scroll; previewImageView = imageView
        let sizeLabel = NSTextField(labelWithString: "\(image.width) × \(image.height) px"); sizeLabel.frame = CGRect(x: 14, y: 50, width: 190, height: 22); sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); root.addSubview(sizeLabel)
        let fit = NSButton(title: "适合宽度", target: self, action: #selector(fitWidth)); fit.frame = CGRect(x: 210, y: 46, width: 78, height: 28); fit.bezelStyle = .rounded; root.addSubview(fit)
        let actual = NSButton(title: "100%", target: self, action: #selector(actualSize)); actual.frame = CGRect(x: 293, y: 46, width: 58, height: 28); actual.bezelStyle = .rounded; root.addSubview(actual)
        let titles = [("复制", CaptureSettings.Output.copy), ("存储", .save), ("复制并存储", .copyAndSave), ("临时贴图", .pin)]
        var x = 14.0
        for (title, output) in titles {
            let button = NSButton(title: title, target: self, action: #selector(output(_:))); button.tag = outputTag(output); button.frame = CGRect(x: x, y: 10, width: title == "复制并存储" ? 94 : 74, height: 28); button.bezelStyle = .rounded; button.toolTip = title; root.addSubview(button); x += button.frame.width + 5
        }
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePreview)); closeButton.frame = CGRect(x: x + 16, y: 10, width: 64, height: 28); closeButton.bezelStyle = .rounded; closeButton.keyEquivalent = "\u{1b}"; root.addSubview(closeButton)
        window.contentView = root
        window.setAccessibilityLabel("长图预览")
    }
    private func outputTag(_ output: CaptureSettings.Output) -> Int { switch output { case .copy: 1; case .save: 2; case .copyAndSave: 3; case .pin: 4 } }
    @objc private func output(_ sender: NSButton) {
        guard !ended, let output: CaptureSettings.Output = [1: .copy, 2: .save, 3: .copyAndSave, 4: .pin][sender.tag] else { return }
        ended = true
        onOutput?(image, output)
    }
    @objc private func fitWidth() {
        fitsWidth = true
        guard let scroll = previewScroll, let imageView = previewImageView else { return }
        let width = max(1, scroll.contentView.bounds.width - 4)
        let ratio = width / CGFloat(image.width)
        imageView.frame = CGRect(x: 0, y: 0, width: width, height: CGFloat(image.height) * ratio)
    }
    @objc private func actualSize() {
        fitsWidth = false
        previewImageView?.frame = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scaleFactor, height: CGFloat(image.height) / scaleFactor)
    }
    func windowDidResize(_ notification: Notification) { if fitsWidth { fitWidth() } }
    func show() { window.center(); window.makeKeyAndOrderFront(nil); fitWidth(); previewScroll?.contentView.scroll(to: CGPoint(x: 0, y: max(0, (previewImageView?.frame.height ?? 0) - previewScroll!.contentView.bounds.height))); previewScroll?.reflectScrolledClipView(previewScroll!.contentView) }
    func close() { window.close() }
    @objc private func closePreview() { close() }
    func windowWillClose(_ notification: Notification) {
        guard !ended else { return }
        ended = true
        onClose?()
    }
}
