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
    private var activeTool: AnnotationTool = .none
    private var activeColor: AnnotationColor = .red
    private var annotations: [Annotation] = []
    private var annotationStart: CGPoint?
    private var annotationCurrent: CGPoint?
    private var fixedSelection: CGRect?
    private var movingFrom: (rect: CGRect, point: CGPoint)?
    private var resizingFrom: (rect: CGRect, point: CGPoint, handle: Handle)?
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let dimensionSeparator = NSTextField(labelWithString: "×")

    private enum Handle {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private enum ToolbarAction {
        case output(CaptureSettings.Output)
        case cancel
        case tool(AnnotationTool)
        case color(AnnotationColor)
    }

    private enum AnnotationTool { case none, line, arrow, number, letter }
    private enum AnnotationColor: CaseIterable {
        case red, orange, blue, green, black
        var color: NSColor {
            switch self { case .red: .systemRed; case .orange: .systemOrange; case .blue: .systemBlue; case .green: .systemGreen; case .black: .black }
        }
    }
    private struct Annotation { let tool: AnnotationTool; let start: CGPoint; let end: CGPoint; let text: String?; let color: AnnotationColor }

    init(frame frameRect: NSRect, capture: CapturedImage, defaultOutput: CaptureSettings.Output) {
        self.capture = capture
        self.defaultOutput = defaultOutput
        super.init(frame: frameRect)
        configureDimensionFields()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        layoutDimensionFields()

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
            let border: NSBezierPath
            switch shape {
            case .rectangle, .square:
                border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            case .circle:
                border = NSBezierPath(ovalIn: selection.insetBy(dx: 0.5, dy: 0.5))
            }
            border.lineWidth = 1
            border.stroke()

            drawDimensions(for: selection, near: dragCurrent ?? CGPoint(x: selection.maxX, y: selection.minY))
            drawToolbar(for: selection)
            drawHandles(for: selection)
            drawAnnotations()
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
        if case .cancel? = toolbarAction(at: point) {
            onCancel?()
            return
        }
        if case let .tool(tool)? = toolbarAction(at: point) {
            activeTool = tool
            needsDisplay = true
            return
        }
        if case let .color(color)? = toolbarAction(at: point) {
            activeColor = color
            needsDisplay = true
            return
        }
        if activeTool == .number || activeTool == .letter, selectionRect?.contains(point) == true {
            let index = annotations.filter { $0.tool == activeTool }.count + 1
            let text = activeTool == .number ? "\(index)" : String(UnicodeScalar(64 + index)!)
            annotations.append(Annotation(tool: activeTool, start: point, end: point, text: text, color: activeColor))
            needsDisplay = true
            return
        }
        if activeTool == .line || activeTool == .arrow, selectionRect?.contains(point) == true {
            annotationStart = point
            annotationCurrent = point
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
        if annotationStart != nil {
            annotationCurrent = point
            needsDisplay = true
            return
        }
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
        if let start = annotationStart, let end = annotationCurrent {
            annotations.append(Annotation(tool: activeTool, start: start, end: end, text: nil, color: activeColor))
            annotationStart = nil
            annotationCurrent = nil
            needsDisplay = true
            return
        }
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
        } else if event.keyCode == 51 || event.keyCode == 117 {
            deleteLastLabel()
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
        return renderAnnotations(on: cropped, selection: selection)
    }

    private func renderAnnotations(on cropped: CGImage, selection: CGRect) -> CGImage? {

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
        if shape == .circle {
            context.clear(CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
            context.addEllipse(in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
            context.clip()
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let xScale = CGFloat(cropped.width) / selection.width
        let yScale = CGFloat(cropped.height) / selection.height
        for annotation in annotations {
            let point: (CGPoint) -> CGPoint = { p in CGPoint(x: (p.x - selection.minX) * xScale, y: (p.y - selection.minY) * yScale) }
            let start = point(annotation.start)
            let end = point(annotation.end)
            context.setStrokeColor(annotation.color.color.cgColor)
            context.setFillColor(annotation.color.color.cgColor)
            context.setLineWidth(max(2, 2 * xScale))
            if annotation.tool == .line || annotation.tool == .arrow {
                context.move(to: start); context.addLine(to: end); context.strokePath()
                if annotation.tool == .arrow {
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let head: CGFloat = 10 * xScale
                    context.move(to: end)
                    context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
                    context.move(to: end)
                    context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
                    context.strokePath()
                }
            } else if let text = annotation.text {
                let radius = 14 * xScale
                context.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13 * xScale), .foregroundColor: NSColor.white]
                let string = NSAttributedString(string: text, attributes: attributes)
                let size = string.size()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                string.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return context.makeImage()
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func drawDimensions(for selection: CGRect, near point: CGPoint) {
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
        let origin = CGPoint(
            x: min(max(point.x + 14, 8), bounds.maxX - size.width - 8),
            y: min(max(point.y + 14, 8), bounds.maxY - size.height - 8)
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

        let toolWidth: CGFloat = 188
        let tools: [(ToolbarAction, String)] = [
            (.tool(.line), "直线"), (.tool(.arrow), "箭头"), (.tool(.number), "数字"), (.tool(.letter), "字母")
        ]
        for (index, tool) in tools.enumerated() {
            let rect = CGRect(x: toolbar.minX + CGFloat(index) * toolWidth / 4, y: toolbar.minY + 64, width: toolWidth / 4, height: 30)
            if case let .tool(candidate) = tool.0, activeTool == candidate {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            let title = NSAttributedString(string: tool.1, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
            let size = title.size(); title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        let colors = AnnotationColor.allCases
        let colorWidth = (toolbar.width - toolWidth) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            let center = CGPoint(x: toolbar.minX + toolWidth + CGFloat(index) * colorWidth + colorWidth / 2, y: toolbar.minY + 79)
            color.color.setFill(); NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)).fill()
            if color == activeColor { NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)); ring.lineWidth = 2; ring.stroke() }
        }

        let actions: [(ToolbarAction, String)] = [
            (.output(.copy), "复制"),
            (.output(.save), "下载"),
            (.output(.copyAndSave), "复制并下载"),
            (.cancel, "取消截图")
        ]
        let buttonWidth = toolbar.width / CGFloat(actions.count)
        for (index, action) in actions.enumerated() {
            let rect = CGRect(
                x: toolbar.minX + CGFloat(index) * buttonWidth,
                y: toolbar.minY,
                width: buttonWidth,
                height: 32
            )
            if case let .output(output) = action.0,
               pendingOutput == output || (pendingOutput == nil && defaultOutput == output) {
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

        let dimensionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75)
        ]
        NSAttributedString(string: "像素", attributes: dimensionAttributes)
            .draw(at: CGPoint(x: toolbar.minX + 8, y: toolbar.minY + 36))
    }

    private func toolbarRect(for selection: CGRect) -> CGRect {
        let width: CGFloat = 304
        let height: CGFloat = 128
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
        guard toolbar.contains(point), point.y <= toolbar.minY + 34 else { return nil }
        guard case let .output(output)? = toolbarAction(at: point) else { return nil }
        return output
    }

    private func shape(at point: CGPoint) -> CaptureSettings.Shape? {
        guard let selection = selectionRect else { return nil }
        let toolbar = toolbarRect(for: selection)
        guard toolbar.contains(point), point.y > toolbar.minY + 96 else { return nil }
        let index = min(2, max(0, Int((point.x - toolbar.minX) / (toolbar.width / 3))))
        return [.rectangle, .square, .circle][index]
    }

    private func toolbarAction(at point: CGPoint) -> ToolbarAction? {
        guard let selection = selectionRect else { return nil }
        let toolbar = toolbarRect(for: selection)
        guard toolbar.contains(point) else { return nil }
        if point.y <= toolbar.minY + 34 {
            let index = min(3, max(0, Int((point.x - toolbar.minX) / (toolbar.width / 4))))
            return [.output(.copy), .output(.save), .output(.copyAndSave), .cancel][index]
        }
        guard point.y > toolbar.minY + 64, point.y <= toolbar.minY + 96 else { return nil }
        let toolWidth: CGFloat = 188
        if point.x < toolbar.minX + toolWidth {
            let index = min(3, max(0, Int((point.x - toolbar.minX) / (toolWidth / 4))))
            return [.tool(.line), .tool(.arrow), .tool(.number), .tool(.letter)][index]
        }
        let colors = AnnotationColor.allCases
        let colorWidth = (toolbar.width - toolWidth) / CGFloat(colors.count)
        let index = min(colors.count - 1, max(0, Int((point.x - toolbar.minX - toolWidth) / colorWidth)))
        return .color(colors[index])
    }

    private func drawAnnotations() {
        for annotation in annotations {
            annotation.color.color.setStroke(); annotation.color.color.setFill()
            let path = NSBezierPath(); path.lineWidth = 2
            if annotation.tool == .line || annotation.tool == .arrow {
                path.move(to: annotation.start); path.line(to: annotation.end); path.stroke()
            } else if let text = annotation.text {
                let rect = CGRect(x: annotation.start.x - 14, y: annotation.start.y - 14, width: 28, height: 28)
                NSBezierPath(ovalIn: rect).fill()
                NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: annotation.start.x - 4, y: annotation.start.y - 7))
            }
        }
        if let start = annotationStart, let end = annotationCurrent {
            NSColor.systemRed.setStroke(); let path = NSBezierPath(); path.lineWidth = 2; path.move(to: start); path.line(to: end); path.stroke()
        }
    }

    private func deleteLastLabel() {
        guard let index = annotations.lastIndex(where: { $0.tool == .number || $0.tool == .letter }) else { return }
        annotations.remove(at: index)
        renumberLabels()
        needsDisplay = true
    }

    private func renumberLabels() {
        var number = 0
        var letter = 0
        annotations = annotations.map { annotation in
            guard annotation.tool == .number || annotation.tool == .letter else { return annotation }
            if annotation.tool == .number {
                number += 1
                return Annotation(tool: annotation.tool, start: annotation.start, end: annotation.end, text: "\(number)", color: annotation.color)
            }
            letter += 1
            return Annotation(tool: annotation.tool, start: annotation.start, end: annotation.end, text: String(UnicodeScalar(64 + letter)!), color: annotation.color)
        }
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

    private func configureDimensionFields() {
        for field in [widthField, heightField] {
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.alignment = .center
            field.isEditable = true
            field.isSelectable = true
            field.focusRingType = .none
            field.target = self
            field.action = #selector(commitDimensionFields)
            field.delegate = self
            addSubview(field)
        }
        dimensionSeparator.alignment = .center
        dimensionSeparator.textColor = .white
        dimensionSeparator.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        dimensionSeparator.isHidden = true
        addSubview(dimensionSeparator)
    }

    private func layoutDimensionFields() {
        guard let selection = selectionRect else {
            widthField.isHidden = true
            heightField.isHidden = true
            dimensionSeparator.isHidden = true
            return
        }
        let toolbar = toolbarRect(for: selection)
        let fieldWidth: CGFloat = 66
        let fieldHeight: CGFloat = 22
        let y = toolbar.minY + 39
        widthField.frame = CGRect(x: toolbar.minX + 34, y: y, width: fieldWidth, height: fieldHeight)
        dimensionSeparator.frame = CGRect(x: toolbar.minX + 103, y: y, width: 18, height: fieldHeight)
        heightField.frame = CGRect(x: toolbar.minX + 122, y: y, width: fieldWidth, height: fieldHeight)
        widthField.isHidden = false
        heightField.isHidden = false
        dimensionSeparator.isHidden = false
        heightField.isEnabled = shape == .rectangle

        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        if window?.firstResponder !== widthField.currentEditor() && window?.firstResponder !== heightField.currentEditor() {
            widthField.stringValue = "\(Int(selection.width * xScale))"
            heightField.stringValue = "\(Int(selection.height * yScale))"
        }
    }

    @objc private func commitDimensionFields() {
        guard let selection = selectionRect,
              let width = Double(widthField.stringValue),
              let height = Double(heightField.stringValue),
              width >= 2,
              height >= 2 else {
            layoutDimensionFields()
            return
        }
        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        let targetWidth = CGFloat(width) / xScale
        let targetHeight = (shape == .rectangle ? CGFloat(height) : CGFloat(width)) / yScale
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let requested = CGRect(
            x: center.x - targetWidth / 2,
            y: center.y - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        fixedSelection = constrained(requested.intersection(bounds))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

extension RegionSelectionView: NSTextFieldDelegate {}
