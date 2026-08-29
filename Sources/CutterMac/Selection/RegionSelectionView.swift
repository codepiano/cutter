import AppKit
import CoreGraphics

@MainActor
final class RegionSelectionView: NSView {
    var onSelection: ((CGImage, CaptureSettings.Output) -> Void)?
    var onCancel: (() -> Void)?

    private let capture: CapturedImage
    private let defaultOutput: CaptureSettings.Output
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var pendingOutput: CaptureSettings.Output?

    init(frame frameRect: NSRect, capture: CapturedImage, defaultOutput: CaptureSettings.Output) {
        self.capture = capture
        self.defaultOutput = defaultOutput
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let background = NSImage(
            cgImage: capture.image,
            size: bounds.size
        )
        background.draw(in: bounds)

        NSColor.black.withAlphaComponent(0.38).setFill()
        if let selection = selectionRect, selection.width > 0, selection.height > 0 {
            let outside = NSBezierPath(rect: bounds)
            outside.appendRect(selection)
            outside.windingRule = .evenOdd
            outside.fill()

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            drawDimensions(for: selection)
            drawToolbar(for: selection)
        } else {
            NSBezierPath.fill(bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let output = output(at: point) {
            pendingOutput = output
            needsDisplay = true
            return
        }
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = clamped(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let output = pendingOutput {
            pendingOutput = nil
            complete(output: output)
            return
        }
        dragCurrent = clamped(convert(event.locationInWindow, from: nil))
        guard let selection = selectionRect,
              selection.width >= 2,
              selection.height >= 2,
              crop(selection) != nil else {
            onCancel?()
            return
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            complete(output: .copy)
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        ).integral.intersection(bounds)
    }

    private func crop(_ selection: CGRect) -> CGImage? {
        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        let pixelRect = CGRect(
            x: selection.minX * xScale,
            y: (bounds.height - selection.maxY) * yScale,
            width: selection.width * xScale,
            height: selection.height * yScale
        ).integral

        return capture.image.cropping(to: pixelRect)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func drawDimensions(for selection: CGRect) {
        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        let label = "\(Int(selection.width * xScale)) × \(Int(selection.height * yScale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        let attributed = NSAttributedString(string: "  \(label)  ", attributes: attributes)
        let size = attributed.size()
        let preferredY = selection.minY - size.height - 6
        let origin = CGPoint(
            x: min(max(selection.minX, 8), bounds.maxX - size.width - 8),
            y: preferredY >= 8 ? preferredY : selection.maxY + 6
        )
        attributed.draw(at: origin)
    }

    private func drawToolbar(for selection: CGRect) {
        let toolbar = toolbarRect(for: selection)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: toolbar, xRadius: 7, yRadius: 7).fill()

        let actions: [(CaptureSettings.Output, String)] = [
            (.copy, "复制"),
            (.save, "下载"),
            (.copyAndSave, "复制并下载")
        ]
        let buttonWidth = toolbar.width / CGFloat(actions.count)
        for (index, action) in actions.enumerated() {
            let rect = CGRect(
                x: toolbar.minX + CGFloat(index) * buttonWidth,
                y: toolbar.minY,
                width: buttonWidth,
                height: toolbar.height
            )
            if pendingOutput == action.0 || (pendingOutput == nil && defaultOutput == action.0) {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let title = NSAttributedString(string: action.1, attributes: attributes)
            let titleSize = title.size()
            title.draw(at: CGPoint(
                x: rect.midX - titleSize.width / 2,
                y: rect.midY - titleSize.height / 2
            ))
        }
    }

    private func toolbarRect(for selection: CGRect) -> CGRect {
        let width: CGFloat = 228
        let height: CGFloat = 34
        let y = selection.minY - height - 8 >= bounds.minY
            ? selection.minY - height - 8
            : selection.maxY + 8
        return CGRect(
            x: min(max(selection.minX, bounds.minX + 8), bounds.maxX - width - 8),
            y: min(max(y, bounds.minY + 8), bounds.maxY - height - 8),
            width: width,
            height: height
        )
    }

    private func output(at point: CGPoint) -> CaptureSettings.Output? {
        guard let selection = selectionRect else { return nil }
        let toolbar = toolbarRect(for: selection)
        guard toolbar.contains(point) else { return nil }
        let index = min(2, max(0, Int((point.x - toolbar.minX) / (toolbar.width / 3))))
        return [.copy, .save, .copyAndSave][index]
    }

    private func complete(output: CaptureSettings.Output) {
        guard let selection = selectionRect,
              selection.width >= 2,
              selection.height >= 2,
              let cropped = crop(selection) else {
            onCancel?()
            return
        }
        onSelection?(cropped, output)
    }
}
