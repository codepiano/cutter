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
    private var activeTool: AnnotationTool = .none
    private var activeColor: AnnotationColor = .red
    private var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var selectedAnnotationIndex: Int?
    private var movingAnnotationFrom: (index: Int, point: CGPoint, annotation: Annotation)?
    private var movingAnnotationDidChange = false
    private var annotationStart: CGPoint?
    private var annotationCurrent: CGPoint?
    private var fixedSelection: CGRect?
    private var movingFrom: (rect: CGRect, point: CGPoint)?
    private var resizingFrom: (rect: CGRect, point: CGPoint, handle: Handle)?
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let dimensionSeparator = NSTextField(labelWithString: "×")
    private let dimensionLabel = NSTextField(labelWithString: "尺寸")
    private let pixelLabel = NSTextField(labelWithString: "px")
    private var shapeButtons: [(shape: CaptureSettings.Shape, button: NSButton)] = []
    private var toolButtons: [(tool: AnnotationTool, button: NSButton)] = []
    private var colorButtons: [(color: AnnotationColor, button: NSButton)] = []
    private var outputButtons: [(output: CaptureSettings.Output, button: NSButton)] = []
    private let cancelButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    private enum Handle {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private enum AnnotationTool { case none, pen, line, arrow, number, letter }
    private enum AnnotationColor: CaseIterable {
        case red, orange, blue, green, black
        var color: NSColor {
            switch self { case .red: .systemRed; case .orange: .systemOrange; case .blue: .systemBlue; case .green: .systemGreen; case .black: .black }
        }
        var name: String {
            switch self { case .red: "红色"; case .orange: "橙色"; case .blue: "蓝色"; case .green: "绿色"; case .black: "黑色" }
        }
    }
    private struct Annotation {
        let tool: AnnotationTool
        let start: CGPoint
        let end: CGPoint
        let text: String?
        let color: AnnotationColor
        let points: [CGPoint]
        init(tool: AnnotationTool, start: CGPoint, end: CGPoint, text: String?, color: AnnotationColor, points: [CGPoint] = []) {
            self.tool = tool; self.start = start; self.end = end; self.text = text; self.color = color; self.points = points
        }
    }
    private var penPoints: [CGPoint] = []

    init(frame frameRect: NSRect, capture: CapturedImage, defaultOutput: CaptureSettings.Output) {
        self.capture = capture
        self.defaultOutput = defaultOutput
        super.init(frame: frameRect)
        configureDimensionFields()
        configureToolbarControls()
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
        layoutToolbarControls()

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
        if let selection = selectionRect, toolbarRect(for: selection).contains(point) {
            return
        }
        if let selection = selectionRect, let handle = handle(at: point) {
            resizingFrom = (selection, point, handle)
            return
        }
        if activeTool == .none, let index = annotation(at: point) {
            selectedAnnotationIndex = index
            movingAnnotationFrom = (index, point, annotations[index])
            movingAnnotationDidChange = false
            needsDisplay = true
            return
        }
        if activeTool == .number || activeTool == .letter, selectionRect?.contains(point) == true {
            let index = annotations.filter { $0.tool == activeTool }.count + 1
            let text = activeTool == .number ? "\(index)" : alphabeticLabel(for: index)
            registerAnnotationChange()
            annotations.append(Annotation(tool: activeTool, start: point, end: point, text: text, color: activeColor))
            needsDisplay = true
            return
        }
        if activeTool == .pen || activeTool == .line || activeTool == .arrow, selectionRect?.contains(point) == true {
            annotationStart = point
            annotationCurrent = point
            penPoints = [point]
            needsDisplay = true
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
        if let movingAnnotationFrom {
            if !movingAnnotationDidChange {
                registerAnnotationChange()
                movingAnnotationDidChange = true
            }
            let dx = point.x - movingAnnotationFrom.point.x
            let dy = point.y - movingAnnotationFrom.point.y
            let original = movingAnnotationFrom.annotation
            annotations[movingAnnotationFrom.index] = Annotation(
                tool: original.tool,
                start: original.start.applying(CGAffineTransform(translationX: dx, y: dy)),
                end: original.end.applying(CGAffineTransform(translationX: dx, y: dy)),
                text: original.text,
                color: original.color,
                points: original.points.map { $0.applying(CGAffineTransform(translationX: dx, y: dy)) }
            )
            needsDisplay = true
            return
        }
        if annotationStart != nil {
            annotationCurrent = point
            if activeTool == .pen { penPoints.append(point) }
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
            registerAnnotationChange()
            annotations.append(Annotation(tool: activeTool, start: start, end: end, text: nil, color: activeColor, points: penPoints))
            annotationStart = nil
            annotationCurrent = nil
            penPoints = []
            needsDisplay = true
            return
        }
        movingAnnotationFrom = nil
        movingAnnotationDidChange = false
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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            modifiers.contains(.shift) ? redoAnnotationChange() : undoAnnotationChange()
        } else if event.keyCode == 53 {
            if activeTool != .none {
                activeTool = .none
                selectedAnnotationIndex = nil
                updateToolbarControlStyles()
                needsDisplay = true
            } else {
                onCancel?()
            }
        } else if event.keyCode == 36 || event.keyCode == 76 {
            complete(output: defaultOutput)
        } else if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedAnnotation()
        } else if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
            let shortcuts: [String: AnnotationTool] = ["v": .none, "p": .pen, "l": .line, "a": .arrow, "n": .number, "t": .letter]
            if let tool = shortcuts[key] {
                activeTool = tool
                selectedAnnotationIndex = nil
                updateToolbarControlStyles()
                needsDisplay = true
            } else {
                super.keyDown(with: event)
            }
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
            if annotation.tool == .pen {
                if let first = annotation.points.first {
                    context.move(to: point(first))
                    for sample in annotation.points.dropFirst() { context.addLine(to: point(sample)) }
                    context.strokePath()
                }
            } else if annotation.tool == .line || annotation.tool == .arrow {
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
        NSBezierPath(roundedRect: toolbar, xRadius: 9, yRadius: 9).fill()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        for offset in [36.0, 66.0, 100.0] {
            let separator = NSBezierPath()
            separator.move(to: CGPoint(x: toolbar.minX + 6, y: toolbar.minY + offset))
            separator.line(to: CGPoint(x: toolbar.maxX - 6, y: toolbar.minY + offset))
            separator.lineWidth = 1
            separator.stroke()
        }
    }

    private func toolbarRect(for selection: CGRect) -> CGRect {
        let inset: CGFloat = 8
        let gap: CGFloat = 8
        let width = max(0, min(380, bounds.width - inset * 2))
        let height = max(0, min(132, bounds.height - inset * 2))
        let safeBounds = bounds.insetBy(dx: inset, dy: inset)
        let candidates = [
            CGRect(x: selection.minX, y: selection.minY - height - gap, width: width, height: height),
            CGRect(x: selection.minX, y: selection.maxY + gap, width: width, height: height),
            CGRect(x: selection.maxX + gap, y: selection.midY - height / 2, width: width, height: height),
            CGRect(x: selection.minX - width - gap, y: selection.midY - height / 2, width: width, height: height)
        ]
        if let available = candidates.first(where: { safeBounds.contains($0) && !$0.intersects(selection) }) {
            return available
        }

        func clamped(_ rect: CGRect) -> CGRect {
            CGRect(
                x: min(max(rect.minX, safeBounds.minX), safeBounds.maxX - rect.width),
                y: min(max(rect.minY, safeBounds.minY), safeBounds.maxY - rect.height),
                width: rect.width,
                height: rect.height
            )
        }
        func overlapArea(_ rect: CGRect) -> CGFloat {
            let overlap = rect.intersection(selection)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return candidates.map(clamped).min { lhs, rhs in
            overlapArea(lhs) < overlapArea(rhs)
        } ?? clamped(candidates[0])
    }

    private func configureToolbarControls() {
        let shapes: [(CaptureSettings.Shape, String)] = [(.rectangle, "矩形"), (.square, "正方形"), (.circle, "圆形")]
        for (candidate, title) in shapes {
            let button = makeToolbarButton(title: title, fontSize: 12)
            button.target = self
            button.action = #selector(selectShape(_:))
            button.toolTip = "选择\(title)选区"
            shapeButtons.append((candidate, button))
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.none, "选择", "V"), (.pen, "画笔", "P"), (.line, "直线", "L"),
            (.arrow, "箭头", "A"), (.number, "数字", "N"), (.letter, "字母", "T")
        ]
        for (tool, title, shortcut) in tools {
            let button = makeToolbarButton(title: title, fontSize: 11)
            button.target = self
            button.action = #selector(selectTool(_:))
            button.toolTip = "\(title)（\(shortcut)）"
            toolButtons.append((tool, button))
        }

        for color in AnnotationColor.allCases {
            let button = makeToolbarButton(title: "", fontSize: 11)
            button.target = self
            button.action = #selector(selectColor(_:))
            button.toolTip = color.name
            button.setAccessibilityLabel("标注颜色：\(color.name)")
            colorButtons.append((color, button))
        }

        let outputs: [(CaptureSettings.Output, String)] = [(.copy, "复制"), (.save, "存储"), (.copyAndSave, "复制并存储")]
        for (output, title) in outputs {
            let button = makeToolbarButton(title: title, fontSize: 12)
            button.target = self
            button.action = #selector(performOutput(_:))
            button.toolTip = output == defaultOutput ? "默认动作，按 Return 执行" : title
            outputButtons.append((output, button))
        }

        configureIconButton(undoButton, symbol: "arrow.uturn.backward", label: "撤销", action: #selector(undoFromToolbar))
        undoButton.toolTip = "撤销（⌘Z）"
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", label: "重做", action: #selector(redoFromToolbar))
        redoButton.toolTip = "重做（⇧⌘Z）"

        configureTextButton(cancelButton, title: "取消", fontSize: 12)
        cancelButton.target = self
        cancelButton.action = #selector(cancelCapture)
        cancelButton.toolTip = "取消截图（Esc）"
        addSubview(cancelButton)

        for label in [dimensionLabel, pixelLabel] {
            label.textColor = NSColor.white.withAlphaComponent(0.72)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            label.isHidden = true
            addSubview(label)
        }
        updateToolbarControlStyles()
    }

    private func makeToolbarButton(title: String, fontSize: CGFloat) -> NSButton {
        let button = NSButton()
        configureTextButton(button, title: title, fontSize: fontSize)
        addSubview(button)
        return button
    }

    private func configureTextButton(_ button: NSButton, title: String, fontSize: CGFloat) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        button.focusRingType = .default
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.isHidden = true
        button.setAccessibilityLabel(title)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.isBordered = false
        button.bezelStyle = .inline
        button.focusRingType = .default
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.target = self
        button.action = action
        button.isHidden = true
        button.setAccessibilityLabel(label)
        addSubview(button)
    }

    private var toolbarViews: [NSView] {
        var views: [NSView] = shapeButtons.map { $0.button }
        views.append(contentsOf: toolButtons.map { $0.button })
        views.append(contentsOf: colorButtons.map { $0.button })
        views.append(contentsOf: outputButtons.map { $0.button })
        views.append(contentsOf: [cancelButton, undoButton, redoButton, dimensionLabel, pixelLabel])
        return views
    }

    private func layoutToolbarControls() {
        guard let selection = selectionRect, selection.width > 0, selection.height > 0 else {
            toolbarViews.forEach { $0.isHidden = true }
            return
        }
        let toolbar = toolbarRect(for: selection)
        toolbarViews.forEach { $0.isHidden = false }

        let innerX = toolbar.minX + 4
        let innerWidth = max(0, toolbar.width - 8)
        let shapeWidth = innerWidth / CGFloat(shapeButtons.count)
        for (index, item) in shapeButtons.enumerated() {
            item.button.frame = CGRect(x: innerX + CGFloat(index) * shapeWidth, y: toolbar.minY + 102, width: shapeWidth, height: 26)
        }

        let colorWidth = min(26, innerWidth / 12)
        let colorTotal = colorWidth * CGFloat(colorButtons.count)
        let toolWidth = max(0, innerWidth - colorTotal - 6)
        let toolButtonWidth = toolWidth / CGFloat(toolButtons.count)
        for (index, item) in toolButtons.enumerated() {
            item.button.frame = CGRect(x: innerX + CGFloat(index) * toolButtonWidth, y: toolbar.minY + 70, width: toolButtonWidth, height: 26)
        }
        for (index, item) in colorButtons.enumerated() {
            item.button.frame = CGRect(x: innerX + toolWidth + 6 + CGFloat(index) * colorWidth + 2, y: toolbar.minY + 73, width: max(16, colorWidth - 4), height: 20)
        }

        dimensionLabel.frame = CGRect(x: innerX + 2, y: toolbar.minY + 42, width: 30, height: 20)
        pixelLabel.frame = CGRect(x: innerX + 188, y: toolbar.minY + 42, width: 20, height: 20)
        undoButton.frame = CGRect(x: toolbar.maxX - 66, y: toolbar.minY + 40, width: 28, height: 22)
        redoButton.frame = CGRect(x: toolbar.maxX - 34, y: toolbar.minY + 40, width: 28, height: 22)

        let actionWeights: [CGFloat] = [0.20, 0.20, 0.36, 0.24]
        var actionX = innerX
        let actionButtons = outputButtons.map(\.button) + [cancelButton]
        for (index, button) in actionButtons.enumerated() {
            let width = innerWidth * actionWeights[index]
            button.frame = CGRect(x: actionX, y: toolbar.minY + 3, width: width, height: 30)
            actionX += width
        }
        updateToolbarControlStyles()
    }

    private func updateToolbarControlStyles() {
        for item in shapeButtons { style(item.button, selected: item.shape == shape) }
        for item in toolButtons { style(item.button, selected: item.tool == activeTool) }
        for item in colorButtons {
            item.button.layer?.backgroundColor = item.color.color.cgColor
            item.button.layer?.cornerRadius = 6
            item.button.layer?.borderWidth = item.color == activeColor ? 2 : 1
            item.button.layer?.borderColor = (item.color == activeColor ? NSColor.white : NSColor.white.withAlphaComponent(0.35)).cgColor
        }
        for item in outputButtons {
            style(item.button, selected: item.output == defaultOutput, prominent: item.output == defaultOutput)
        }
        style(cancelButton, selected: false)
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        for button in [undoButton, redoButton] {
            button.alphaValue = button.isEnabled ? 1 : 0.38
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(button.isEnabled ? 0.08 : 0.03).cgColor
        }
    }

    private func style(_ button: NSButton, selected: Bool, prominent: Bool = false) {
        button.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(prominent ? 1 : 0.82).cgColor
            : NSColor.white.withAlphaComponent(0.06).cgColor
        button.layer?.borderWidth = selected ? 0 : 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    @objc private func selectShape(_ sender: NSButton) {
        guard let candidate = shapeButtons.first(where: { $0.button === sender })?.shape else { return }
        shape = candidate
        if let selection = fixedSelection { fixedSelection = constrained(selection) }
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = toolButtons.first(where: { $0.button === sender })?.tool else { return }
        activeTool = tool
        selectedAnnotationIndex = nil
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let color = colorButtons.first(where: { $0.button === sender })?.color else { return }
        activeColor = color
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func performOutput(_ sender: NSButton) {
        guard let output = outputButtons.first(where: { $0.button === sender })?.output else { return }
        complete(output: output)
    }

    @objc private func cancelCapture() { onCancel?() }
    @objc private func undoFromToolbar() { undoAnnotationChange() }
    @objc private func redoFromToolbar() { redoAnnotationChange() }

    private func drawAnnotations() {
        for (index, annotation) in annotations.enumerated() {
            annotation.color.color.setStroke(); annotation.color.color.setFill()
            let path = NSBezierPath(); path.lineWidth = 2
            if annotation.tool == .pen {
                if let first = annotation.points.first {
                    path.move(to: first)
                    for point in annotation.points.dropFirst() { path.line(to: point) }
                    path.stroke()
                }
            } else if annotation.tool == .line || annotation.tool == .arrow {
                path.move(to: annotation.start); path.line(to: annotation.end); path.stroke()
                if annotation.tool == .arrow { drawArrowHead(from: annotation.start, to: annotation.end) }
            } else if let text = annotation.text {
                let rect = CGRect(x: annotation.start.x - 14, y: annotation.start.y - 14, width: 28, height: 28)
                NSBezierPath(ovalIn: rect).fill()
                let title = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white])
                let size = title.size()
                title.draw(at: CGPoint(x: annotation.start.x - size.width / 2, y: annotation.start.y - size.height / 2))
            }
            if index == selectedAnnotationIndex { drawSelectionOutline(for: annotation) }
        }
        if let start = annotationStart, let end = annotationCurrent {
            activeColor.color.setStroke(); let path = NSBezierPath(); path.lineWidth = 2
            if activeTool == .pen, let first = penPoints.first {
                path.move(to: first)
                for point in penPoints.dropFirst() { path.line(to: point) }
            } else {
                path.move(to: start); path.line(to: end)
            }
            path.stroke()
            if activeTool == .arrow { drawArrowHead(from: start, to: end) }
        }
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 10
        let path = NSBezierPath()
        path.lineWidth = 2
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
        path.stroke()
    }

    private func drawSelectionOutline(for annotation: Annotation) {
        let rect: CGRect
        if annotation.tool == .pen, let first = annotation.points.first {
            let xs = annotation.points.map(\.x)
            let ys = annotation.points.map(\.y)
            rect = CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y, width: (xs.max() ?? first.x) - (xs.min() ?? first.x), height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
        } else if annotation.tool == .number || annotation.tool == .letter {
            rect = CGRect(x: annotation.start.x - 17, y: annotation.start.y - 17, width: 34, height: 34)
        } else {
            rect = CGRect(x: min(annotation.start.x, annotation.end.x), y: min(annotation.start.y, annotation.end.y), width: abs(annotation.end.x - annotation.start.x), height: abs(annotation.end.y - annotation.start.y))
        }
        NSColor.white.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 4, yRadius: 4)
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.lineWidth = 1.5
        outline.stroke()
    }

    private func deleteSelectedAnnotation() {
        let index = selectedAnnotationIndex ?? annotations.indices.last
        guard let index, annotations.indices.contains(index) else { return }
        registerAnnotationChange()
        annotations.remove(at: index)
        selectedAnnotationIndex = nil
        renumberLabels()
        updateToolbarControlStyles()
        needsDisplay = true
    }

    private func annotation(at point: CGPoint) -> Int? {
        annotations.lastIndex { annotation in
            switch annotation.tool {
            case .number, .letter:
                return hypot(annotation.start.x - point.x, annotation.start.y - point.y) <= 18
            case .line, .arrow:
                return distance(from: point, toSegmentFrom: annotation.start, to: annotation.end) <= 8
            case .pen:
                return annotation.points.contains { hypot($0.x - point.x, $0.y - point.y) <= 8 }
            case .none:
                return false
            }
        }
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func registerAnnotationChange() {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateToolbarControlStyles()
    }

    private func undoAnnotationChange() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedAnnotationIndex = nil
        updateToolbarControlStyles()
        needsDisplay = true
    }

    private func redoAnnotationChange() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedAnnotationIndex = nil
        updateToolbarControlStyles()
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
            return Annotation(tool: annotation.tool, start: annotation.start, end: annotation.end, text: alphabeticLabel(for: letter), color: annotation.color)
        }
    }

    private func alphabeticLabel(for index: Int) -> String {
        var value = max(1, index)
        var label = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(65 + value % 26)!
            label = String(Character(scalar)) + label
            value /= 26
        }
        return label
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
        for (field, label) in [(widthField, "宽度（像素）"), (heightField, "高度（像素）")] {
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.alignment = .center
            field.isEditable = true
            field.isSelectable = true
            field.focusRingType = .default
            field.target = self
            field.action = #selector(commitDimensionFields)
            field.delegate = self
            field.setAccessibilityLabel(label)
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
        widthField.frame = CGRect(x: toolbar.minX + 38, y: y, width: fieldWidth, height: fieldHeight)
        dimensionSeparator.frame = CGRect(x: toolbar.minX + 104, y: y, width: 18, height: fieldHeight)
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
            NSSound.beep()
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
