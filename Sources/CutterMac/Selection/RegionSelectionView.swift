import AppKit
import CoreGraphics

@MainActor
final class RegionSelectionView: NSView {
    var onSelection: ((CGImage, CaptureSettings.Output) -> Void)?
    var onCancel: (() -> Void)?

    private let capture: CapturedImage
    private let defaultOutput: CaptureSettings.Output
    private var shape: CaptureSettings.Shape = .rectangle
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var pendingOutput: CaptureSettings.Output?
    private var fixedSelection: CGRect?
    private var movingFrom: (rect: CGRect, point: CGPoint)?
    private var resizingFrom: (rect: CGRect, point: CGPoint, handle: Handle)?

    private enum Handle {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

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
            let border = shape == .rectangle
                ? NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
                : NSBezierPath(ovalIn: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            drawDimensions(for: selection)
            drawToolbar(for: selection)
            drawHandles(for: selection)
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
        if let newShape = shape(at: point) {
            shape = newShape
            if let selection = fixedSelection {
                fixedSelection = constrained(selection)
            }
            needsDisplay = true
            return
        }
        if let selection = selectionRect, let handle = handle(at: point) {
            resizingFrom = (selection, point, handle)
            return
        }
        if let selection = selectionRect, selection.contains(point) {
            movingFrom = (selection, point)
            return
        }
        dragStart = point
        dragCurrent = point
        fixedSelection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let movingFrom {
            let dx = point.x - movingFrom.point.x
            let dy = point.y - movingFrom.point.y
            fixedSelection = movedRect(movingFrom.rect, dx: dx, dy: dy)
        } else if let resizingFrom {
            fixedSelection = resizedRect(
                resizingFrom.rect,
                from: resizingFrom.point,
                to: point,
                handle: resizingFrom.handle
            )
        } else {
            dragCurrent = point
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let output = pendingOutput {
            pendingOutput = nil
            complete(output: output)
            return
        }
        movingFrom = nil
        resizingFrom = nil
        dragCurrent = clamped(convert(event.locationInWindow, from: nil))
        guard let selection = selectionRect,
              selection.width >= 2,
              selection.height >= 2,
              crop(selection) != nil else {
            onCancel?()
            return
        }
        fixedSelection = selection
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
        if let fixedSelection { return fixedSelection }
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return constrained(CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        ).integral.intersection(bounds))
    }

    private func constrained(_ rect: CGRect) -> CGRect {
        guard shape != .rectangle else { return rect }
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
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

        guard let cropped = capture.image.cropping(to: pixelRect) else { return nil }
        guard shape == .circle else { return cropped }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.addEllipse(in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.clip()
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
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

        let shapes: [(CaptureSettings.Shape, String)] = [
            (.rectangle, "矩形"), (.square, "正方形"), (.circle, "圆形")
        ]
        let shapeWidth = toolbar.width / CGFloat(shapes.count)
        for (index, candidate) in shapes.enumerated() {
            let rect = CGRect(
                x: toolbar.minX + CGFloat(index) * shapeWidth,
                y: toolbar.maxY - 32,
                width: shapeWidth,
                height: 30
            )
            if shape == candidate.0 {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            let title = NSAttributedString(string: candidate.1, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ])
            let size = title.size()
            title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY + 1 - size.height / 2))
        }

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
                height: 32
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
        let height: CGFloat = 68
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
        guard point.y <= toolbar.minY + 34 else { return nil }
        let index = min(2, max(0, Int((point.x - toolbar.minX) / (toolbar.width / 3))))
        return [.copy, .save, .copyAndSave][index]
    }

    private func shape(at point: CGPoint) -> CaptureSettings.Shape? {
        guard let selection = selectionRect else { return nil }
        let toolbar = toolbarRect(for: selection)
        guard toolbar.contains(point), point.y > toolbar.minY + 34 else { return nil }
        let index = min(2, max(0, Int((point.x - toolbar.minX) / (toolbar.width / 3))))
        return [.rectangle, .square, .circle][index]
    }

    private func drawHandles(for selection: CGRect) {
        let radius: CGFloat = 4
        for point in handlePoints(for: selection) {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)
        ]
    }

    private func handle(at point: CGPoint) -> Handle? {
        guard let rect = selectionRect else { return nil }
        let handles: [(Handle, CGPoint)] = zip(
            [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight],
            handlePoints(for: rect)
        ).map { ($0.0, $0.1) }
        return handles.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= 12 })?.0
    }

    private func movedRect(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var moved = rect.offsetBy(dx: dx, dy: dy)
        if moved.minX < bounds.minX { moved.origin.x = bounds.minX }
        if moved.minY < bounds.minY { moved.origin.y = bounds.minY }
        if moved.maxX > bounds.maxX { moved.origin.x = bounds.maxX - moved.width }
        if moved.maxY > bounds.maxY { moved.origin.y = bounds.maxY - moved.height }
        return moved
    }

    private func resizedRect(_ rect: CGRect, from start: CGPoint, to point: CGPoint, handle: Handle) -> CGRect {
        var result = rect
        switch handle {
        case .topLeft: result = CGRect(x: point.x, y: rect.minY, width: rect.maxX - point.x, height: point.y - rect.minY)
        case .top: result.size.height = max(2, point.y - rect.minY)
        case .topRight: result = CGRect(x: rect.minX, y: rect.minY, width: point.x - rect.minX, height: point.y - rect.minY)
        case .left: result = CGRect(x: point.x, y: rect.minY, width: rect.maxX - point.x, height: rect.height)
        case .right: result.size.width = max(2, point.x - rect.minX)
        case .bottomLeft: result = CGRect(x: point.x, y: point.y, width: rect.maxX - point.x, height: rect.maxY - point.y)
        case .bottom: result = CGRect(x: rect.minX, y: point.y, width: rect.width, height: rect.maxY - point.y)
        case .bottomRight: result = CGRect(x: rect.minX, y: rect.minY, width: point.x - rect.minX, height: point.y - rect.minY)
        }
        if result.width < 2 { result.size.width = 2 }
        if result.height < 2 { result.size.height = 2 }
        return constrained(result).intersection(bounds)
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
