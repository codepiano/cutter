import AppKit
import CoreImage
import CoreGraphics

@MainActor
final class RegionSelectionView: NSView {
    var onSelection: ((CGImage, CaptureSettings.Output) -> Void)?
    var onCancel: (() -> Void)?

    private let capture: CapturedImage
    private let defaultOutput: CaptureSettings.Output
    private let captureWindows: [CapturableWindow]
    private let windowCaptureProvider: (@Sendable (CGWindowID) async throws -> CapturedImage)?
    private var shape: CaptureSettings.Shape = .rectangle
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var activeTool: AnnotationTool = .none
    private var activeColor: AnnotationColor = .red
    private var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var selectedAnnotationIndex: Int?
    private var additionalSelectedAnnotationIndices: Set<Int> = []
    private var annotationLineWidth: CGFloat = 2
    private var annotationFontSize: CGFloat = 16
    private var movingAnnotationsFrom: [(index: Int, point: CGPoint, annotation: Annotation)]?
    private var movingAnnotationDidChange = false
    private var annotationStart: CGPoint?
    private var annotationCurrent: CGPoint?
    private var activePrivacySeed: UInt64?
    private var fixedSelection: CGRect?
    private var movingFrom: (
        rect: CGRect,
        point: CGPoint,
        annotations: [Annotation],
        undoStack: [[Annotation]],
        redoStack: [[Annotation]]
    )?
    private var resizingFrom: (rect: CGRect, point: CGPoint, handle: Handle)?
    private var windowSelectionEnabled = true
    private var hoveredWindowID: CGWindowID?
    private var pressedWindowID: CGWindowID?
    private var windowPressPoint: CGPoint?
    private var selectedWindowID: CGWindowID?
    private var isCompleting = false
    private var pointerTrackingArea: NSTrackingArea?
    private let textAnnotationField = NSTextField()
    private var pendingTextPoint: CGPoint?
    private let coreImageContext = CIContext()
    private let lineWidthButton = NSButton()
    private let fontSizeButton = NSButton()
    private let duplicateAnnotationButton = NSButton()
    private let bringForwardButton = NSButton()
    private let sendBackwardButton = NSButton()
    private let alignAnnotationButton = NSButton()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let dimensionSeparator = NSTextField(labelWithString: "×")
    private let dimensionLabel = NSTextField(labelWithString: "尺寸")
    private let pixelLabel = NSTextField(labelWithString: "px")
    private let dimensionApplyButton = NSButton()
    private let presetButton = NSButton()
    private let presetStore: CaptureSizePresetStore
    private var dimensionFeedbackState: DimensionFeedbackState = .idle
    private var invalidWidth = false
    private var invalidHeight = false
    private var dimensionFeedbackReset: DispatchWorkItem?
    private var shapeButtons: [(shape: CaptureSettings.Shape, button: NSButton)] = []
    private var toolButtons: [(tool: AnnotationTool, button: NSButton)] = []
    private var colorButtons: [(color: AnnotationColor, button: NSButton)] = []
    private let customColorWell = NSColorWell(style: .expanded)
    private var originalColorPanelLevel: NSWindow.Level?
    private var originalColorPanelShowsAlpha: Bool?
    private var outputButtons: [(output: CaptureSettings.Output, button: NSButton)] = []
    private let cancelButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    private enum Handle {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private enum DimensionFeedbackState {
        case idle, editing, success, error
    }

    private enum AnnotationTool {
        case none, pen, line, arrow, number, letter, rectangle, text, highlight, mosaic, blur
    }
    private struct AnnotationColor: Equatable {
        static let red = AnnotationColor(color: .systemRed, name: "红色")
        static let orange = AnnotationColor(color: .systemOrange, name: "橙色")
        static let blue = AnnotationColor(color: .systemBlue, name: "蓝色")
        static let green = AnnotationColor(color: .systemGreen, name: "绿色")
        static let black = AnnotationColor(color: .black, name: "黑色")
        static let presets = [red, orange, blue, green, black]

        let color: NSColor
        let name: String

        init(color: NSColor, name: String) {
            self.color = color.usingColorSpace(.sRGB) ?? color
            self.name = name
        }

        static func == (lhs: AnnotationColor, rhs: AnnotationColor) -> Bool {
            guard let left = lhs.color.usingColorSpace(.sRGB),
                  let right = rhs.color.usingColorSpace(.sRGB) else {
                return lhs.color == rhs.color
            }
            return abs(left.redComponent - right.redComponent) < 0.001
                && abs(left.greenComponent - right.greenComponent) < 0.001
                && abs(left.blueComponent - right.blueComponent) < 0.001
                && abs(left.alphaComponent - right.alphaComponent) < 0.001
        }
    }
    private struct Annotation {
        let tool: AnnotationTool
        let start: CGPoint
        let end: CGPoint
        let text: String?
        let color: AnnotationColor
        let points: [CGPoint]
        let privacySeed: UInt64?
        let lineWidth: CGFloat
        let fontSize: CGFloat
        init(
            tool: AnnotationTool,
            start: CGPoint,
            end: CGPoint,
            text: String?,
            color: AnnotationColor,
            points: [CGPoint] = [],
            privacySeed: UInt64? = nil,
            lineWidth: CGFloat = 2,
            fontSize: CGFloat = 18
        ) {
            self.tool = tool
            self.start = start
            self.end = end
            self.text = text
            self.color = color
            self.points = points
            self.privacySeed = privacySeed
            self.lineWidth = lineWidth
            self.fontSize = fontSize
        }
    }
    private var penPoints: [CGPoint] = []

    init(
        frame frameRect: NSRect,
        capture: CapturedImage,
        defaultOutput: CaptureSettings.Output,
        presetStore: CaptureSizePresetStore = CaptureSizePresetStore(),
        captureWindows: [CapturableWindow] = [],
        windowCaptureProvider: (@Sendable (CGWindowID) async throws -> CapturedImage)? = nil
    ) {
        self.capture = capture
        self.defaultOutput = defaultOutput
        self.presetStore = presetStore
        self.captureWindows = captureWindows
        self.windowCaptureProvider = windowCaptureProvider
        super.init(frame: frameRect)
        windowSelectionEnabled = !captureWindows.isEmpty
        configureDimensionFields()
        configureTextAnnotationField()
        configureToolbarControls()
        configureAnnotationContextControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard fixedSelection == nil, windowSelectionEnabled else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        let nextWindowID = window(at: point)?.id
        guard hoveredWindowID != nextWindowID else { return }
        hoveredWindowID = nextWindowID
        needsDisplay = true
    }

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
            case .stamp:
                border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            }
            border.lineWidth = 1
            border.stroke()
            if shape == .stamp { drawStampPerforations(in: selection) }

            if fixedSelection == nil {
                drawDimensions(for: selection, near: dragCurrent ?? CGPoint(x: selection.maxX, y: selection.minY))
            }
            drawToolbar(for: selection)
            drawHandles(for: selection)
            drawAnnotations()
        } else if windowSelectionEnabled,
                  let hoveredWindowID,
                  let hoveredWindow = captureWindows.first(where: { $0.id == hoveredWindowID }),
                  let windowRect = localRect(for: hoveredWindow) {
            let outside = NSBezierPath(rect: bounds)
            outside.appendRect(windowRect)
            outside.windingRule = .evenOdd
            outside.fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: windowRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 2
            border.stroke()
            drawWindowHint(for: hoveredWindow, rect: windowRect)
        } else {
            NSBezierPath.fill(bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let selection = selectionRect, toolbarRect(for: selection).contains(point) {
            return
        }
        if selectionRect == nil,
           windowSelectionEnabled,
           let candidate = window(at: point) {
            pressedWindowID = candidate.id
            windowPressPoint = point
            dragStart = point
            dragCurrent = point
            needsDisplay = true
            return
        }
        if let selection = selectionRect, let handle = handle(at: point) {
            setPresetButtonTitle(nil)
            selectedWindowID = nil
            resizingFrom = (selection, point, handle)
            return
        }
        if activeTool == .none, let index = annotation(at: point) {
            var indices = selectedAnnotationIndices
            if event.modifierFlags.contains(.shift) {
                if indices.contains(index) { indices.remove(index) } else { indices.insert(index) }
            } else {
                indices = [index]
            }
            setAnnotationSelection(indices)
            guard indices.contains(index) else {
                needsDisplay = true
                return
            }
            movingAnnotationsFrom = indices.sorted().compactMap { annotationIndex in
                guard annotations.indices.contains(annotationIndex) else { return nil }
                return (annotationIndex, point, annotations[annotationIndex])
            }
            movingAnnotationDidChange = false
            needsDisplay = true
            return
        }
        if activeTool == .text, selectionRect?.contains(point) == true {
            beginTextAnnotation(at: point)
            return
        }
        if activeTool == .number || activeTool == .letter, selectionRect?.contains(point) == true {
            let index = annotations.filter { $0.tool == activeTool }.count + 1
            let text = activeTool == .number ? "\(index)" : alphabeticLabel(for: index)
            registerAnnotationChange()
            annotations.append(Annotation(
                tool: activeTool,
                start: point,
                end: point,
                text: text,
                color: activeColor,
                fontSize: annotationFontSize
            ))
            setAnnotationSelection([annotations.count - 1])
            needsDisplay = true
            return
        }
        if [.pen, .line, .arrow, .rectangle, .highlight, .mosaic, .blur].contains(activeTool),
           selectionRect?.contains(point) == true {
            annotationStart = point
            annotationCurrent = point
            penPoints = [point]
            activePrivacySeed = (activeTool == .mosaic || activeTool == .blur) ? randomPrivacySeed() : nil
            needsDisplay = true
            return
        }
        if let selection = selectionRect, selection.contains(point) {
            selectedWindowID = nil
            movingFrom = (selection, point, annotations, undoStack, redoStack)
            return
        }
        dragStart = point
        dragCurrent = point
        fixedSelection = nil
        selectedWindowID = nil
        setPresetButtonTitle(nil)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let windowPressPoint {
            guard hypot(point.x - windowPressPoint.x, point.y - windowPressPoint.y) > 4 else { return }
            pressedWindowID = nil
            hoveredWindowID = nil
            self.windowPressPoint = nil
            dragStart = windowPressPoint
            dragCurrent = point
            needsDisplay = true
            return
        }
        if let movingAnnotationsFrom {
            if !movingAnnotationDidChange {
                registerAnnotationChange()
                movingAnnotationDidChange = true
            }
            guard let anchor = movingAnnotationsFrom.first else { return }
            let dx = point.x - anchor.point.x
            let dy = point.y - anchor.point.y
            for movingAnnotation in movingAnnotationsFrom {
                annotations[movingAnnotation.index] = translated(movingAnnotation.annotation, dx: dx, dy: dy)
            }
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
            let movedSelection = movedRect(movingFrom.rect, dx: dx, dy: dy)
            let appliedDX = movedSelection.minX - movingFrom.rect.minX
            let appliedDY = movedSelection.minY - movingFrom.rect.minY
            fixedSelection = movedSelection
            annotations = movingFrom.annotations.map {
                translated($0, dx: appliedDX, dy: appliedDY)
            }
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
        if let pressedWindowID, let windowPressPoint {
            let point = clamped(convert(event.locationInWindow, from: nil))
            self.pressedWindowID = nil
            self.windowPressPoint = nil
            if hypot(point.x - windowPressPoint.x, point.y - windowPressPoint.y) <= 4,
               let selectedWindow = captureWindows.first(where: { $0.id == pressedWindowID }),
               let selectedRect = localRect(for: selectedWindow) {
                shape = .rectangle
                fixedSelection = selectedRect.integral
                selectedWindowID = pressedWindowID
                hoveredWindowID = nil
                dragStart = nil
                dragCurrent = nil
                updateToolbarControlStyles()
                needsDisplay = true
                return
            }
        }
        if let start = annotationStart, let end = annotationCurrent {
            registerAnnotationChange()
            annotations.append(Annotation(
                tool: activeTool,
                start: start,
                end: end,
                text: nil,
                color: activeColor,
                points: penPoints,
                privacySeed: activePrivacySeed,
                lineWidth: annotationLineWidth,
                fontSize: annotationFontSize
            ))
            setAnnotationSelection([annotations.count - 1])
            annotationStart = nil
            annotationCurrent = nil
            penPoints = []
            activePrivacySeed = nil
            needsDisplay = true
            return
        }
        movingAnnotationsFrom = nil
        movingAnnotationDidChange = false
        if let movingFrom, let movedSelection = selectionRect {
            let appliedDX = movedSelection.minX - movingFrom.rect.minX
            let appliedDY = movedSelection.minY - movingFrom.rect.minY
            undoStack = movingFrom.undoStack.map { snapshot in
                snapshot.map { translated($0, dx: appliedDX, dy: appliedDY) }
            }
            redoStack = movingFrom.redoStack.map { snapshot in
                snapshot.map { translated($0, dx: appliedDX, dy: appliedDY) }
            }
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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 49, fixedSelection == nil, !captureWindows.isEmpty {
            windowSelectionEnabled.toggle()
            hoveredWindowID = nil
            pressedWindowID = nil
            windowPressPoint = nil
            needsDisplay = true
        } else if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            modifiers.contains(.shift) ? redoAnnotationChange() : undoAnnotationChange()
        } else if event.keyCode == 53 {
            if activeTool != .none {
                activeTool = .none
                setAnnotationSelection([])
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
            let shortcuts: [String: AnnotationTool] = [
                "v": .none, "p": .pen, "l": .line, "a": .arrow, "n": .number, "t": .letter,
                "r": .rectangle, "x": .text, "h": .highlight, "m": .mosaic, "b": .blur
            ]
            if let tool = shortcuts[key] {
                activeTool = tool
                setAnnotationSelection([])
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
        guard shape.locksAspectRatio else { return rect }
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
            context.setLineWidth(max(1, annotation.lineWidth * xScale))
            if annotation.tool == .mosaic || annotation.tool == .blur {
                applyPrivacyEffect(annotation, in: context, rect: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
            } else if annotation.tool == .rectangle {
                context.stroke(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
            } else if annotation.tool == .highlight {
                context.saveGState()
                context.setAlpha(0.32)
                context.setLineWidth(max(10, annotation.lineWidth * 4 * xScale))
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
                context.restoreGState()
            } else if annotation.tool == .text, let text = annotation.text {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: annotation.fontSize * xScale, weight: .semibold),
                    .foregroundColor: annotation.color.color
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSAttributedString(string: text, attributes: attributes).draw(at: start)
                NSGraphicsContext.restoreGraphicsState()
            } else if annotation.tool == .pen {
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
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: max(11, annotation.fontSize * 0.8 * xScale)), .foregroundColor: NSColor.white]
                let string = NSAttributedString(string: text, attributes: attributes)
                let size = string.size()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                string.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if shape == .stamp {
            context.saveGState()
            context.setBlendMode(.clear)
            let outputRect = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
            let outputScale = min(xScale, yScale)
            for hole in stampHoleRects(
                in: outputRect,
                preferredDiameter: 8 * outputScale,
                preferredSpacing: 15 * outputScale
            ) {
                context.fillEllipse(in: hole)
            }
            context.restoreGState()
        }
        return context.makeImage()
    }

    private func applyPrivacyEffect(_ annotation: Annotation, in context: CGContext, rect: CGRect) {
        let effectRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard !effectRect.isNull, effectRect.width >= 2, effectRect.height >= 2,
              let image = randomPrivacyImage(
                  width: Int(effectRect.width.rounded()),
                  height: Int(effectRect.height.rounded()),
                  tool: annotation.tool,
                  seed: annotation.privacySeed ?? 0
              ) else { return }
        context.draw(image, in: effectRect)
    }

    private struct PrivacyRandom {
        var state: UInt64

        mutating func nextUnit() -> CGFloat {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            value ^= value >> 31
            return CGFloat(value >> 11) / CGFloat(1 << 53)
        }
    }

    private func randomPrivacySeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }

    private func randomPrivacyImage(
        width: Int,
        height: Int,
        tool: AnnotationTool,
        seed: UInt64
    ) -> CGImage? {
        guard width > 1, height > 1 else { return nil }
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }

        var random = PrivacyRandom(state: seed == 0 ? 0xC0FFEE : seed)
        let blockSize = tool == .mosaic
            ? max(6, min(18, min(width, height) / 10))
            : max(14, min(32, min(width, height) / 6))
        for y in stride(from: 0, to: height, by: blockSize) {
            for x in stride(from: 0, to: width, by: blockSize) {
                let red = 0.18 + random.nextUnit() * 0.64
                let green = 0.18 + random.nextUnit() * 0.64
                let blue = 0.18 + random.nextUnit() * 0.64
                context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
                context.fill(CGRect(
                    x: x,
                    y: y,
                    width: min(blockSize, width - x),
                    height: min(blockSize, height - y)
                ))
            }
        }
        guard let image = context.makeImage() else { return nil }
        guard tool == .blur else { return image }
        let input = CIImage(cgImage: image)
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10])
            .cropped(to: input.extent)
        return coreImageContext.createCGImage(blurred, from: input.extent)
    }

    private func drawStampPerforations(in selection: CGRect) {
        let holes = stampHoleRects(in: selection, preferredDiameter: 8, preferredSpacing: 15)
        NSColor.black.withAlphaComponent(0.38).setFill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        for hole in holes {
            let path = NSBezierPath(ovalIn: hole)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func stampHoleRects(
        in rect: CGRect,
        preferredDiameter: CGFloat,
        preferredSpacing: CGFloat
    ) -> [CGRect] {
        guard min(rect.width, rect.height) >= 12 else { return [] }
        let diameter = min(preferredDiameter, min(rect.width, rect.height) / 5)
        let radius = diameter / 2
        let margin = diameter * 1.25
        let horizontal = stampPositions(
            from: rect.minX + margin,
            to: rect.maxX - margin,
            preferredSpacing: max(preferredSpacing, diameter * 1.5)
        )
        let vertical = stampPositions(
            from: rect.minY + margin,
            to: rect.maxY - margin,
            preferredSpacing: max(preferredSpacing, diameter * 1.5)
        )
        var holes: [CGRect] = []
        for x in horizontal {
            holes.append(CGRect(x: x - radius, y: rect.minY - radius, width: diameter, height: diameter))
            holes.append(CGRect(x: x - radius, y: rect.maxY - radius, width: diameter, height: diameter))
        }
        for y in vertical {
            holes.append(CGRect(x: rect.minX - radius, y: y - radius, width: diameter, height: diameter))
            holes.append(CGRect(x: rect.maxX - radius, y: y - radius, width: diameter, height: diameter))
        }
        return holes
    }

    private func stampPositions(from start: CGFloat, to end: CGFloat, preferredSpacing: CGFloat) -> [CGFloat] {
        guard end > start else { return [(start + end) / 2] }
        let intervalCount = max(1, Int(((end - start) / preferredSpacing).rounded()))
        let spacing = (end - start) / CGFloat(intervalCount)
        return (0...intervalCount).map { start + CGFloat($0) * spacing }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func window(at point: CGPoint) -> CapturableWindow? {
        captureWindows.first(where: { window in
            localRect(for: window)?.contains(point) == true
        })
    }

    private func localRect(for window: CapturableWindow) -> CGRect? {
        guard window.displayID == capture.displayID else { return nil }
        let displayBounds = CGDisplayBounds(capture.displayID)
        let rect = CGRect(
            x: window.frame.minX - displayBounds.minX,
            y: displayBounds.maxY - window.frame.maxY,
            width: window.frame.width,
            height: window.frame.height
        ).intersection(bounds)
        return rect.isNull || rect.width < 2 || rect.height < 2 ? nil : rect
    }

    private func drawWindowHint(for window: CapturableWindow, rect: CGRect) {
        let primaryText = window.title.isEmpty
            ? window.ownerName
            : "\(window.ownerName) · \(window.title)"
        let primary = NSAttributedString(string: primaryText, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        let secondary = NSAttributedString(string: "单击选择窗口 · 拖动自由区域 · Space 切换", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ])
        let width = min(max(primary.size().width, secondary.size().width) + 20, bounds.width - 16)
        let height: CGFloat = 46
        let preferredY = rect.minY - height - 8 >= bounds.minY + 8
            ? rect.minY - height - 8
            : rect.maxY + 8
        let box = CGRect(
            x: min(max(rect.minX, bounds.minX + 8), bounds.maxX - width - 8),
            y: min(max(preferredY, bounds.minY + 8), bounds.maxY - height - 8),
            width: width,
            height: height
        )
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        primary.draw(
            with: CGRect(x: box.minX + 10, y: box.minY + 23, width: box.width - 20, height: 16),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        )
        secondary.draw(
            with: CGRect(x: box.minX + 10, y: box.minY + 7, width: box.width - 20, height: 14),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
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
        NSColor.black.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: toolbar, xRadius: 12, yRadius: 12).fill()

        NSColor.white.withAlphaComponent(0.035).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: toolbar.minX + 4, y: toolbar.maxY - 40, width: toolbar.width - 8, height: 36),
            xRadius: 8,
            yRadius: 8
        ).fill()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        let separatorOffsets: [CGFloat] = selectedAnnotationIndices.isEmpty ? [42] : [42, 78]
        for offset in separatorOffsets {
            let separator = NSBezierPath()
            separator.move(to: CGPoint(x: toolbar.minX + 8, y: toolbar.minY + offset))
            separator.line(to: CGPoint(x: toolbar.maxX - 8, y: toolbar.minY + offset))
            separator.lineWidth = 1
            separator.stroke()
        }
    }

    private func toolbarRect(for selection: CGRect) -> CGRect {
        let inset: CGFloat = 8
        let gap: CGFloat = 8
        let width = max(0, min(980, bounds.width - inset * 2))
        let requestedHeight: CGFloat = selectedAnnotationIndices.isEmpty ? 84 : 122
        let height = max(0, min(requestedHeight, bounds.height - inset * 2))
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
        let shapes: [(CaptureSettings.Shape, String)] = [
            (.rectangle, "矩形"), (.square, "正方形"), (.circle, "圆形"), (.stamp, "邮票")
        ]
        for (candidate, title) in shapes {
            let button = makeToolbarButton(title: title, fontSize: 12)
            button.target = self
            button.action = #selector(selectShape(_:))
            button.toolTip = "选择\(title)选区"
            shapeButtons.append((candidate, button))
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.none, "选择", "V"), (.pen, "画笔", "P"), (.line, "直线", "L"),
            (.arrow, "箭头", "A"), (.number, "数字", "N"), (.letter, "字母", "T"),
            (.rectangle, "矩形框", "R"), (.text, "文本", "X"), (.highlight, "高亮", "H"),
            (.mosaic, "马赛克", "M"), (.blur, "模糊", "B")
        ]
        for (tool, title, shortcut) in tools {
            let button = makeToolbarButton(title: title, fontSize: 11)
            button.target = self
            button.action = #selector(selectTool(_:))
            button.toolTip = "\(title)（\(shortcut)）"
            toolButtons.append((tool, button))
        }

        for color in AnnotationColor.presets {
            let button = makeToolbarButton(title: "", fontSize: 11)
            button.target = self
            button.action = #selector(selectColor(_:))
            button.toolTip = color.name
            button.setAccessibilityLabel("标注颜色：\(color.name)")
            colorButtons.append((color, button))
        }

        customColorWell.color = activeColor.color
        customColorWell.supportsAlpha = false
        customColorWell.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "系统调色板")
        customColorWell.target = self
        customColorWell.action = #selector(selectCustomColor(_:))
        customColorWell.toolTip = "自定义标注颜色"
        customColorWell.focusRingType = .default
        customColorWell.isHidden = true
        customColorWell.setAccessibilityLabel("自定义标注颜色")
        addSubview(customColorWell)
        prepareColorPanel()

        let outputs: [(CaptureSettings.Output, String)] = [
            (.copy, "复制"), (.save, "存储"), (.copyAndSave, "复制并存储"), (.pin, "临时贴图")
        ]
        for (output, title) in outputs {
            let button = makeToolbarButton(title: title, fontSize: 12)
            button.target = self
            button.action = #selector(performOutput(_:))
            button.toolTip = output == .pin
                ? "临时显示截图，不写入文件；关闭窗口后移除"
                : (output == defaultOutput ? "默认动作，按 Return 执行" : title)
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

        configureTextButton(dimensionApplyButton, title: "应用", fontSize: 11)
        dimensionApplyButton.target = self
        dimensionApplyButton.action = #selector(applyDimensionsFromButton)
        dimensionApplyButton.toolTip = "应用宽度和高度（Return）"
        dimensionApplyButton.setAccessibilityLabel("应用尺寸")
        addSubview(dimensionApplyButton)

        configureTextButton(presetButton, title: "预设…", fontSize: 11)
        presetButton.target = self
        presetButton.action = #selector(showSizePresetMenu(_:))
        presetButton.toolTip = "选择或管理常用截图尺寸"
        presetButton.setAccessibilityLabel("尺寸预设")
        addSubview(presetButton)

        for label in [dimensionLabel, pixelLabel] {
            label.textColor = NSColor.white.withAlphaComponent(0.72)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            label.isHidden = true
            addSubview(label)
        }
        updateToolbarControlStyles()
    }

    private func prepareColorPanel() {
        let panel = NSColorPanel.shared
        originalColorPanelLevel = panel.level
        originalColorPanelShowsAlpha = panel.showsAlpha
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.showsAlpha = false
    }

    func closeAuxiliaryPanels() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        let panel = NSColorPanel.shared
        panel.orderOut(nil)
        if let originalColorPanelLevel { panel.level = originalColorPanelLevel }
        if let originalColorPanelShowsAlpha { panel.showsAlpha = originalColorPanelShowsAlpha }
        originalColorPanelLevel = nil
        originalColorPanelShowsAlpha = nil
    }

    private func configureTextAnnotationField() {
        textAnnotationField.font = NSFont.systemFont(ofSize: annotationFontSize, weight: .semibold)
        textAnnotationField.textColor = activeColor.color
        textAnnotationField.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        textAnnotationField.drawsBackground = true
        textAnnotationField.isBezeled = true
        textAnnotationField.bezelStyle = .roundedBezel
        textAnnotationField.focusRingType = .default
        textAnnotationField.target = self
        textAnnotationField.action = #selector(commitTextAnnotation)
        textAnnotationField.delegate = self
        textAnnotationField.isHidden = true
        textAnnotationField.setAccessibilityLabel("标注文本")
        addSubview(textAnnotationField)
    }

    private func configureAnnotationContextControls() {
        configureTextButton(lineWidthButton, title: "线宽 2", fontSize: 11)
        lineWidthButton.target = self
        lineWidthButton.action = #selector(showLineWidthMenu(_:))
        lineWidthButton.toolTip = "设置选中标注的线宽"
        lineWidthButton.setAccessibilityLabel("线宽")
        addSubview(lineWidthButton)

        configureTextButton(fontSizeButton, title: "字号 18", fontSize: 11)
        fontSizeButton.target = self
        fontSizeButton.action = #selector(showFontSizeMenu(_:))
        fontSizeButton.toolTip = "设置选中标注的字号"
        fontSizeButton.setAccessibilityLabel("字号")
        addSubview(fontSizeButton)

        let commands: [(NSButton, String, Selector, String)] = [
            (duplicateAnnotationButton, "复制", #selector(duplicateSelectedAnnotations), "复制选中标注"),
            (bringForwardButton, "前移", #selector(bringSelectedAnnotationsForward), "将选中标注前移一层"),
            (sendBackwardButton, "后移", #selector(sendSelectedAnnotationsBackward), "将选中标注后移一层"),
            (alignAnnotationButton, "对齐…", #selector(showAlignmentMenu(_:)), "对齐选中标注")
        ]
        for (button, title, action, label) in commands {
            configureTextButton(button, title: title, fontSize: 11)
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
        updateAnnotationContextControls()
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
        views.append(customColorWell)
        views.append(contentsOf: outputButtons.map { $0.button })
        views.append(contentsOf: [cancelButton, undoButton, redoButton, dimensionApplyButton, presetButton, dimensionLabel, pixelLabel])
        views.append(contentsOf: annotationContextViews)
        return views
    }

    private var annotationContextViews: [NSView] {
        [lineWidthButton, fontSizeButton, duplicateAnnotationButton, bringForwardButton, sendBackwardButton, alignAnnotationButton]
    }

    private var selectedAnnotationIndices: Set<Int> {
        var indices = additionalSelectedAnnotationIndices
        if let selectedAnnotationIndex { indices.insert(selectedAnnotationIndex) }
        return indices
    }

    private func setAnnotationSelection(_ indices: Set<Int>) {
        let valid = indices.filter { annotations.indices.contains($0) }.sorted()
        selectedAnnotationIndex = valid.first
        additionalSelectedAnnotationIndices = Set(valid.dropFirst())
        updateAnnotationContextControls()
    }

    private func layoutToolbarControls() {
        guard let selection = selectionRect, selection.width > 0, selection.height > 0 else {
            toolbarViews.forEach { $0.isHidden = true }
            return
        }
        let toolbar = toolbarRect(for: selection)
        toolbarViews.forEach { $0.isHidden = false }

        let innerX = toolbar.minX + 6
        let innerWidth = max(0, toolbar.width - 12)
        let hasContext = !selectedAnnotationIndices.isEmpty
        let topY = toolbar.maxY - 37
        let topHeight: CGFloat = 30
        let gap: CGFloat = 8

        let shapeGroupWidth = min(190, innerWidth * 0.27)
        let colorGroupWidth = min(180, innerWidth * 0.25)
        let historyGroupWidth: CGFloat = min(60, innerWidth * 0.10)
        let toolGroupWidth = max(
            0,
            innerWidth - shapeGroupWidth - colorGroupWidth - historyGroupWidth - gap * 3
        )

        let shapeWidth = shapeGroupWidth / CGFloat(shapeButtons.count)
        for (index, item) in shapeButtons.enumerated() {
            item.button.frame = CGRect(
                x: innerX + CGFloat(index) * shapeWidth,
                y: topY,
                width: shapeWidth,
                height: topHeight
            )
        }

        let toolX = innerX + shapeGroupWidth + gap
        let toolButtonWidth = toolGroupWidth / CGFloat(toolButtons.count)
        for (index, item) in toolButtons.enumerated() {
            item.button.frame = CGRect(
                x: toolX + CGFloat(index) * toolButtonWidth,
                y: topY,
                width: toolButtonWidth,
                height: topHeight
            )
        }

        let colorX = toolX + toolGroupWidth + gap
        let colorWellWidth = min(42, colorGroupWidth * 0.25)
        let swatchGroupWidth = max(0, colorGroupWidth - colorWellWidth - 6)
        let colorWidth = swatchGroupWidth / CGFloat(colorButtons.count)
        for (index, item) in colorButtons.enumerated() {
            item.button.frame = CGRect(
                x: colorX + CGFloat(index) * colorWidth + 2,
                y: topY + 3,
                width: max(18, colorWidth - 4),
                height: 24
            )
        }
        customColorWell.frame = CGRect(
            x: colorX + swatchGroupWidth + 6,
            y: topY + 1,
            width: colorWellWidth,
            height: 28
        )

        let contextY = toolbar.minY + 46
        let contextButtons = annotationContextViews.compactMap { $0 as? NSButton }
        if hasContext {
            let contextWidths: [CGFloat] = [116, 116, 70, 70, 70, 76]
            var contextX = innerX
            for (index, button) in contextButtons.enumerated() {
                let width = min(contextWidths[index], max(0, innerWidth / CGFloat(contextButtons.count)))
                button.frame = CGRect(x: contextX, y: contextY, width: width, height: 28)
                contextX += width + 4
            }
        }

        let historyX = colorX + colorGroupWidth + gap
        undoButton.frame = CGRect(x: historyX, y: topY + 2, width: historyGroupWidth / 2, height: 26)
        redoButton.frame = CGRect(x: historyX + historyGroupWidth / 2, y: topY + 2, width: historyGroupWidth / 2, height: 26)

        let bottomY = toolbar.minY + 6
        dimensionLabel.frame = CGRect(x: innerX + 2, y: bottomY + 5, width: 30, height: 20)
        pixelLabel.frame = CGRect(x: innerX + 188, y: bottomY + 5, width: 20, height: 20)
        dimensionApplyButton.frame = CGRect(x: innerX + 214, y: bottomY, width: 56, height: 30)
        presetButton.frame = CGRect(x: innerX + 278, y: bottomY, width: 74, height: 30)

        let actionX = innerX + 360
        let actionWidth = max(0, innerWidth - 360)
        let actionWeights: [CGFloat] = [0.16, 0.16, 0.30, 0.18, 0.20]
        var nextActionX = actionX
        let actionButtons = outputButtons.map(\.button) + [cancelButton]
        for (index, button) in actionButtons.enumerated() {
            let width = actionWidth * actionWeights[index]
            button.frame = CGRect(x: nextActionX, y: bottomY, width: width, height: 30)
            nextActionX += width
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
        customColorWell.color = activeColor.color
        customColorWell.setAccessibilityValue(activeColor.name)
        for item in outputButtons {
            style(item.button, selected: item.output == defaultOutput, prominent: item.output == defaultOutput)
        }
        style(cancelButton, selected: false)
        style(presetButton, selected: false)
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        for button in [undoButton, redoButton] {
            button.alphaValue = button.isEnabled ? 1 : 0.38
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(button.isEnabled ? 0.08 : 0.03).cgColor
        }
        updateDimensionFeedbackStyle()
        updateAnnotationContextControls()
    }

    private func style(_ button: NSButton, selected: Bool, prominent: Bool = false) {
        button.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(prominent ? 1 : 0.82).cgColor
            : NSColor.white.withAlphaComponent(0.06).cgColor
        button.layer?.borderWidth = selected ? 0 : 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    private func updateAnnotationContextControls() {
        let indices = selectedAnnotationIndices.filter { annotations.indices.contains($0) }
        annotationContextViews.forEach { $0.isHidden = indices.isEmpty }
        guard !indices.isEmpty else { return }
        let selected = indices.compactMap { annotations.indices.contains($0) ? annotations[$0] : nil }
        let primary = selected.first
        if let primary {
            setContextButtonTitle(lineWidthButton, title: "线宽 \(Int(primary.lineWidth.rounded()))")
            setContextButtonTitle(fontSizeButton, title: "字号 \(Int(primary.fontSize.rounded()))")
        }
        let canChangeLineWidth = selected.contains { [.pen, .line, .arrow, .rectangle, .highlight].contains($0.tool) }
        let canChangeFontSize = selected.contains { [.number, .letter, .text].contains($0.tool) }
        lineWidthButton.isEnabled = canChangeLineWidth
        fontSizeButton.isEnabled = canChangeFontSize
        duplicateAnnotationButton.isEnabled = true
        bringForwardButton.isEnabled = true
        sendBackwardButton.isEnabled = true
        alignAnnotationButton.isEnabled = indices.count >= 2
    }

    private func setContextButtonTitle(_ button: NSButton, title: String) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        button.needsDisplay = true
    }

    @objc private func showLineWidthMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "线宽")
        let selected = selectedAnnotationIndices.filter { annotations.indices.contains($0) }
        for value in [1, 2, 4, 6, 8] {
            let item = NSMenuItem(title: "\(value) px", action: #selector(applyLineWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = selected.contains { annotations[$0].lineWidth == CGFloat(value) } ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func applyLineWidth(_ sender: NSMenuItem) {
        let value = CGFloat(sender.tag)
        let indices = selectedAnnotationIndices
        guard !indices.isEmpty else { return }
        registerAnnotationChange()
        annotationLineWidth = value
        annotations = annotations.enumerated().map { index, annotation in
            indices.contains(index) ? replacing(annotation, lineWidth: value) : annotation
        }
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func showFontSizeMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "字号")
        let selected = selectedAnnotationIndices.filter { annotations.indices.contains($0) }
        for value in [12, 14, 16, 18, 22, 28, 36] {
            let item = NSMenuItem(title: "\(value) pt", action: #selector(applyFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = selected.contains { annotations[$0].fontSize == CGFloat(value) } ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func applyFontSize(_ sender: NSMenuItem) {
        let value = CGFloat(sender.tag)
        let indices = selectedAnnotationIndices
        guard !indices.isEmpty else { return }
        registerAnnotationChange()
        annotationFontSize = value
        annotations = annotations.enumerated().map { index, annotation in
            indices.contains(index) ? replacing(annotation, fontSize: value) : annotation
        }
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func duplicateSelectedAnnotations() {
        let indices = selectedAnnotationIndices.sorted()
        guard !indices.isEmpty else { return }
        registerAnnotationChange()
        let copies = indices.compactMap { annotations.indices.contains($0) ? translated(annotations[$0], dx: 14, dy: -14) : nil }
        let startIndex = annotations.count
        annotations.append(contentsOf: copies)
        setAnnotationSelection(Set(startIndex..<(startIndex + copies.count)))
        needsDisplay = true
    }

    @objc private func bringSelectedAnnotationsForward() {
        reorderSelectedAnnotations(forward: true)
    }

    @objc private func sendSelectedAnnotationsBackward() {
        reorderSelectedAnnotations(forward: false)
    }

    private func reorderSelectedAnnotations(forward: Bool) {
        var selected = selectedAnnotationIndices
        guard !selected.isEmpty else { return }
        registerAnnotationChange()
        if forward {
            for index in selected.sorted(by: >) {
                let target = index + 1
                guard target < annotations.count, !selected.contains(target) else { continue }
                annotations.swapAt(index, target)
                selected.remove(index); selected.insert(target)
            }
        } else {
            for index in selected.sorted() {
                let target = index - 1
                guard target >= 0, !selected.contains(target) else { continue }
                annotations.swapAt(index, target)
                selected.remove(index); selected.insert(target)
            }
        }
        setAnnotationSelection(selected)
        needsDisplay = true
    }

    @objc private func showAlignmentMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "对齐")
        let items: [(String, Int)] = [("左对齐", 0), ("水平居中", 1), ("右对齐", 2), ("顶部对齐", 3), ("垂直居中", 4), ("底部对齐", 5)]
        for (title, tag) in items {
            let item = NSMenuItem(title: title, action: #selector(applyAlignment(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func applyAlignment(_ sender: NSMenuItem) {
        let indices = selectedAnnotationIndices.sorted()
        guard indices.count >= 2 else { return }
        let bounds = indices.compactMap { annotations.indices.contains($0) ? annotationBounds(annotations[$0]) : nil }
        guard let first = bounds.first else { return }
        let targetX: CGFloat?
        let targetY: CGFloat?
        switch sender.tag {
        case 0: targetX = bounds.map(\.minX).min() ?? first.minX; targetY = nil
        case 1: targetX = bounds.map(\.midX).reduce(0, +) / CGFloat(bounds.count); targetY = nil
        case 2: targetX = bounds.map(\.maxX).max() ?? first.maxX; targetY = nil
        case 3: targetX = nil; targetY = bounds.map(\.maxY).max() ?? first.maxY
        case 4: targetX = nil; targetY = bounds.map(\.midY).reduce(0, +) / CGFloat(bounds.count)
        default: targetX = nil; targetY = bounds.map(\.minY).min() ?? first.minY
        }
        registerAnnotationChange()
        annotations = annotations.enumerated().map { index, annotation in
            guard indices.contains(index) else { return annotation }
            let current = annotationBounds(annotation)
            let dx: CGFloat
            let dy: CGFloat
            switch sender.tag {
            case 0: dx = (targetX ?? current.minX) - current.minX; dy = 0
            case 1: dx = (targetX ?? current.midX) - current.midX; dy = 0
            case 2: dx = (targetX ?? current.maxX) - current.maxX; dy = 0
            case 3: dx = 0; dy = (targetY ?? current.maxY) - current.maxY
            case 4: dx = 0; dy = (targetY ?? current.midY) - current.midY
            default: dx = 0; dy = (targetY ?? current.minY) - current.minY
            }
            return translated(annotation, dx: dx, dy: dy)
        }
        needsDisplay = true
    }

    private func updateDimensionFeedbackStyle() {
        let accent: NSColor
        let title: String
        let accessibilityValue: String
        switch dimensionFeedbackState {
        case .idle:
            accent = NSColor.white.withAlphaComponent(0.22)
            title = "应用"
            accessibilityValue = "尺寸未修改"
        case .editing:
            accent = NSColor.controlAccentColor
            title = "应用"
            accessibilityValue = "尺寸已修改，等待应用"
        case .success:
            accent = NSColor.systemGreen
            title = "已应用"
            accessibilityValue = "尺寸已应用"
        case .error:
            accent = NSColor.systemRed
            title = "检查数值"
            accessibilityValue = "尺寸输入无效"
        }

        for (field, invalid) in [(widthField, invalidWidth), (heightField, invalidHeight)] {
            let fieldAccent = invalid
                ? NSColor.systemRed
                : (dimensionFeedbackState == .error ? NSColor.white.withAlphaComponent(0.22) : accent)
            field.wantsLayer = true
            field.layer?.cornerRadius = 6
            field.layer?.borderWidth = dimensionFeedbackState == .idle ? 1 : 2
            field.layer?.borderColor = fieldAccent.cgColor
            field.needsDisplay = true
        }

        dimensionApplyButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        dimensionApplyButton.isEnabled = dimensionFeedbackState != .idle
        dimensionApplyButton.alphaValue = dimensionFeedbackState == .idle ? 0.52 : 1
        dimensionApplyButton.layer?.backgroundColor = dimensionFeedbackState == .idle
            ? NSColor.white.withAlphaComponent(0.05).cgColor
            : accent.withAlphaComponent(dimensionFeedbackState == .editing ? 0.88 : 1).cgColor
        dimensionApplyButton.layer?.borderWidth = dimensionFeedbackState == .idle ? 1 : 0
        dimensionApplyButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        dimensionApplyButton.setAccessibilityValue(accessibilityValue)
        dimensionApplyButton.needsDisplay = true
    }

    private func setDimensionFeedback(
        _ state: DimensionFeedbackState,
        invalidWidth: Bool = false,
        invalidHeight: Bool = false,
        resetAfter delay: TimeInterval? = nil
    ) {
        dimensionFeedbackReset?.cancel()
        dimensionFeedbackState = state
        self.invalidWidth = invalidWidth
        self.invalidHeight = invalidHeight
        updateDimensionFeedbackStyle()

        guard let delay else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.setDimensionFeedback(.idle)
        }
        dimensionFeedbackReset = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @objc private func selectShape(_ sender: NSButton) {
        guard let candidate = shapeButtons.first(where: { $0.button === sender })?.shape else { return }
        if candidate != .rectangle { selectedWindowID = nil }
        shape = candidate
        if let selection = fixedSelection { fixedSelection = constrained(selection) }
        setDimensionFeedback(.idle)
        setPresetButtonTitle(nil)
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = toolButtons.first(where: { $0.button === sender })?.tool else { return }
        if !textAnnotationField.isHidden { commitTextAnnotation() }
        activeTool = tool
        setAnnotationSelection([])
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let color = colorButtons.first(where: { $0.button === sender })?.color else { return }
        activeColor = color
        textAnnotationField.textColor = activeColor.color
        updateToolbarControlStyles()
        needsDisplay = true
    }

    @objc private func selectCustomColor(_ sender: NSColorWell) {
        activeColor = AnnotationColor(color: sender.color, name: "自定义颜色")
        textAnnotationField.textColor = activeColor.color
        updateToolbarControlStyles()
        needsDisplay = true
    }

    private func beginTextAnnotation(at point: CGPoint) {
        guard let selection = selectionRect else { return }
        let width = min(260, max(120, selection.maxX - point.x))
        let origin = CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX - width),
            y: min(max(point.y - 14, selection.minY), selection.maxY - 30)
        )
        pendingTextPoint = origin
        textAnnotationField.frame = CGRect(x: origin.x, y: origin.y, width: width, height: 30)
        textAnnotationField.stringValue = ""
        textAnnotationField.textColor = activeColor.color
        textAnnotationField.isHidden = false
        window?.makeFirstResponder(textAnnotationField)
    }

    @objc private func commitTextAnnotation() {
        guard !textAnnotationField.isHidden, let start = pendingTextPoint else { return }
        let text = textAnnotationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotationFontSize, weight: .semibold),
                .foregroundColor: activeColor.color
            ]
            let size = NSAttributedString(string: text, attributes: attributes).size()
            registerAnnotationChange()
            annotations.append(Annotation(
                tool: .text,
                start: start,
                end: CGPoint(x: start.x + size.width, y: start.y + size.height),
                text: text,
                color: activeColor
            ))
            setAnnotationSelection([annotations.count - 1])
        }
        cancelTextAnnotation()
        needsDisplay = true
    }

    private func cancelTextAnnotation() {
        textAnnotationField.isHidden = true
        textAnnotationField.stringValue = ""
        pendingTextPoint = nil
        window?.makeFirstResponder(self)
    }

    @objc private func performOutput(_ sender: NSButton) {
        guard let output = outputButtons.first(where: { $0.button === sender })?.output else { return }
        complete(output: output)
    }

    @objc private func showSizePresetMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "尺寸预设")
        menu.autoenablesItems = false
        menu.addItem(menuHeader("内置尺寸"))
        for preset in CaptureSizePreset.builtIns {
            menu.addItem(presetMenuItem(preset, action: #selector(applySizePreset(_:))))
        }

        let customPresets = presetStore.customPresets
        if !customPresets.isEmpty {
            menu.addItem(.separator())
            menu.addItem(menuHeader("自定义尺寸"))
            for preset in customPresets {
                menu.addItem(presetMenuItem(preset, action: #selector(applySizePreset(_:))))
            }
        }

        menu.addItem(.separator())
        let saveItem = NSMenuItem(title: "保存当前尺寸为预设", action: #selector(saveCurrentSizePreset), keyEquivalent: "")
        saveItem.target = self
        saveItem.isEnabled = true
        menu.addItem(saveItem)

        if !customPresets.isEmpty {
            let deleteItem = NSMenuItem(title: "删除自定义预设", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu(title: "删除自定义预设")
            for preset in customPresets {
                deleteMenu.addItem(presetMenuItem(preset, action: #selector(confirmDeleteSizePreset(_:))))
            }
            deleteItem.submenu = deleteMenu
            deleteItem.isEnabled = true
            menu.addItem(deleteItem)
        }

        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func menuHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func presetMenuItem(_ preset: CaptureSizePreset, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: preset.title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = preset.identifier
        item.isEnabled = true
        return item
    }

    private func preset(from menuItem: NSMenuItem) -> CaptureSizePreset? {
        guard let identifier = menuItem.representedObject as? String else { return nil }
        let parts = identifier.split(separator: "x", maxSplits: 1).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return CaptureSizePreset(width: parts[0], height: parts[1])
    }

    @objc private func applySizePreset(_ sender: NSMenuItem) {
        guard let preset = preset(from: sender) else { return }
        selectedWindowID = nil
        if preset.width != preset.height && shape.locksAspectRatio {
            shape = .rectangle
            updateToolbarControlStyles()
        }
        widthField.stringValue = "\(preset.width)"
        heightField.stringValue = "\(preset.height)"
        setDimensionFeedback(.editing)
        commitDimensionFields()
        setPresetButtonTitle(currentSelectionSizePreset()?.compactTitle ?? preset.compactTitle)
    }

    @objc private func saveCurrentSizePreset() {
        guard let preset = presetFromDimensionFields() else { return }
        commitDimensionFields()
        let added = presetStore.add(preset)
        setPresetButtonTitle(preset.compactTitle)
        presetButton.toolTip = added
            ? "已保存自定义尺寸：\(preset.title)"
            : "尺寸预设已存在：\(preset.title)"
        if !added { NSSound.beep() }
    }

    @objc private func confirmDeleteSizePreset(_ sender: NSMenuItem) {
        guard let preset = preset(from: sender) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除自定义尺寸预设？"
        alert.informativeText = preset.title
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.window.level = .screenSaver
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if presetStore.remove(preset), presetButton.attributedTitle.string == preset.compactTitle {
            setPresetButtonTitle(nil)
        }
    }

    private func presetFromDimensionFields() -> CaptureSizePreset? {
        let parsedWidth = Double(widthField.stringValue)
        let parsedHeight = Double(heightField.stringValue)
        let widthIsValid = parsedWidth.map { $0.isFinite && $0.rounded() == $0 } ?? false
        let heightIsValid = shape.locksAspectRatio
            || (parsedHeight.map { $0.isFinite && $0.rounded() == $0 } ?? false)
        guard widthIsValid,
              heightIsValid,
              let width = parsedWidth.map(Int.init) else {
            NSSound.beep()
            setDimensionFeedback(
                .error,
                invalidWidth: !widthIsValid,
                invalidHeight: !heightIsValid
            )
            return nil
        }
        let height = shape.locksAspectRatio ? width : parsedHeight.map(Int.init) ?? width
        guard let preset = CaptureSizePreset(width: width, height: height) else {
            NSSound.beep()
            setDimensionFeedback(.error, invalidWidth: true, invalidHeight: !shape.locksAspectRatio)
            return nil
        }
        return preset
    }

    private func currentSelectionSizePreset() -> CaptureSizePreset? {
        guard let selection = selectionRect else { return nil }
        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        return CaptureSizePreset(
            width: Int((selection.width * xScale).rounded()),
            height: Int((selection.height * yScale).rounded())
        )
    }

    private func setPresetButtonTitle(_ presetTitle: String?) {
        let title = presetTitle ?? "预设…"
        presetButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        presetButton.toolTip = presetTitle.map { "当前尺寸预设：\($0)" } ?? "选择或管理常用截图尺寸"
        presetButton.needsDisplay = true
    }

    @objc private func cancelCapture() { onCancel?() }
    @objc private func undoFromToolbar() { undoAnnotationChange() }
    @objc private func redoFromToolbar() { redoAnnotationChange() }
    @objc private func applyDimensionsFromButton() { commitDimensionFields() }

    private func drawAnnotations() {
        for (index, annotation) in annotations.enumerated() {
            annotation.color.color.setStroke(); annotation.color.color.setFill()
            let path = NSBezierPath(); path.lineWidth = annotation.lineWidth
            let rect = annotationRect(for: annotation)
            if annotation.tool == .mosaic || annotation.tool == .blur {
                if let image = previewPrivacyEffect(for: annotation, rect: rect) {
                    NSImage(cgImage: image, size: rect.size).draw(in: rect)
                }
            } else if annotation.tool == .rectangle {
                path.appendRect(rect)
                path.stroke()
            } else if annotation.tool == .highlight {
                annotation.color.color.withAlphaComponent(0.32).setStroke()
                path.lineWidth = max(10, annotationLineWidth * 4)
                path.lineCapStyle = .round
                path.move(to: annotation.start)
                path.line(to: annotation.end)
                path.stroke()
            } else if annotation.tool == .text, let text = annotation.text {
                let title = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold),
                    .foregroundColor: annotation.color.color
                ])
                title.draw(at: annotation.start)
            } else if annotation.tool == .pen {
                if let first = annotation.points.first {
                    path.move(to: first)
                    for point in annotation.points.dropFirst() { path.line(to: point) }
                    path.stroke()
                }
            } else if annotation.tool == .line || annotation.tool == .arrow {
                path.move(to: annotation.start); path.line(to: annotation.end); path.stroke()
                if annotation.tool == .arrow { drawArrowHead(from: annotation.start, to: annotation.end) }
            } else if (annotation.tool == .number || annotation.tool == .letter), let text = annotation.text {
                let rect = CGRect(x: annotation.start.x - 14, y: annotation.start.y - 14, width: 28, height: 28)
                NSBezierPath(ovalIn: rect).fill()
                let title = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: annotation.fontSize), .foregroundColor: NSColor.white])
                let size = title.size()
                title.draw(at: CGPoint(x: annotation.start.x - size.width / 2, y: annotation.start.y - size.height / 2))
            }
            if selectedAnnotationIndices.contains(index) { drawSelectionOutline(for: annotation) }
        }
        if let start = annotationStart, let end = annotationCurrent {
            activeColor.color.setStroke(); let path = NSBezierPath(); path.lineWidth = annotationLineWidth
            if activeTool == .rectangle {
                path.appendRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
            } else if activeTool == .mosaic || activeTool == .blur {
                let previewAnnotation = Annotation(
                    tool: activeTool,
                    start: start,
                    end: end,
                    text: nil,
                    color: activeColor,
                    privacySeed: activePrivacySeed
                )
                let rect = annotationRect(for: previewAnnotation)
                if let image = previewPrivacyEffect(for: previewAnnotation, rect: rect) {
                    NSImage(cgImage: image, size: rect.size).draw(in: rect)
                }
                path.appendRect(rect)
            } else if activeTool == .highlight {
                activeColor.color.withAlphaComponent(0.32).setStroke()
                path.lineWidth = max(10, annotationLineWidth * 4)
                path.lineCapStyle = .round
                path.move(to: start); path.line(to: end)
            } else if activeTool == .pen, let first = penPoints.first {
                path.move(to: first)
                for point in penPoints.dropFirst() { path.line(to: point) }
            } else {
                path.move(to: start); path.line(to: end)
            }
            path.stroke()
            if activeTool == .arrow { drawArrowHead(from: start, to: end) }
        }
    }

    private func annotationRect(for annotation: Annotation) -> CGRect {
        CGRect(
            x: min(annotation.start.x, annotation.end.x),
            y: min(annotation.start.y, annotation.end.y),
            width: abs(annotation.end.x - annotation.start.x),
            height: abs(annotation.end.y - annotation.start.y)
        )
    }

    private func previewPrivacyEffect(for annotation: Annotation, rect: CGRect) -> CGImage? {
        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        let pixelRect = CGRect(
            x: rect.minX * xScale,
            y: (bounds.height - rect.maxY) * yScale,
            width: rect.width * xScale,
            height: rect.height * yScale
        ).integral
        guard pixelRect.width >= 2, pixelRect.height >= 2 else { return nil }
        return randomPrivacyImage(
            width: Int(pixelRect.width.rounded()),
            height: Int(pixelRect.height.rounded()),
            tool: annotation.tool,
            seed: annotation.privacySeed ?? 0
        )
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
        let indices = selectedAnnotationIndices.isEmpty ? Set(annotations.indices.suffix(1)) : selectedAnnotationIndices
        guard !indices.isEmpty else { return }
        registerAnnotationChange()
        for index in indices.sorted(by: >) where annotations.indices.contains(index) {
            annotations.remove(at: index)
        }
        setAnnotationSelection([])
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
            case .highlight:
                return distance(from: point, toSegmentFrom: annotation.start, to: annotation.end) <= 12
            case .rectangle, .mosaic, .blur, .text:
                return annotationRect(for: annotation).insetBy(dx: -6, dy: -6).contains(point)
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

    private func translated(_ annotation: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        let transform = CGAffineTransform(translationX: dx, y: dy)
        return Annotation(
            tool: annotation.tool,
            start: annotation.start.applying(transform),
            end: annotation.end.applying(transform),
            text: annotation.text,
            color: annotation.color,
            points: annotation.points.map { $0.applying(transform) },
            privacySeed: annotation.privacySeed,
            lineWidth: annotation.lineWidth,
            fontSize: annotation.fontSize
        )
    }

    private func replacing(_ annotation: Annotation, text: String? = nil, lineWidth: CGFloat? = nil, fontSize: CGFloat? = nil) -> Annotation {
        Annotation(
            tool: annotation.tool,
            start: annotation.start,
            end: annotation.end,
            text: text ?? annotation.text,
            color: annotation.color,
            points: annotation.points,
            privacySeed: annotation.privacySeed,
            lineWidth: lineWidth ?? annotation.lineWidth,
            fontSize: fontSize ?? annotation.fontSize
        )
    }

    private func annotationBounds(_ annotation: Annotation) -> CGRect {
        if annotation.tool == .pen, let first = annotation.points.first {
            let xs = annotation.points.map(\.x)
            let ys = annotation.points.map(\.y)
            return CGRect(
                x: xs.min() ?? first.x,
                y: ys.min() ?? first.y,
                width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                height: (ys.max() ?? first.y) - (ys.min() ?? first.y)
            )
        }
        if annotation.tool == .number || annotation.tool == .letter {
            return CGRect(x: annotation.start.x - 14, y: annotation.start.y - 14, width: 28, height: 28)
        }
        return annotationRect(for: annotation)
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
        setAnnotationSelection([])
        updateToolbarControlStyles()
        needsDisplay = true
    }

    private func redoAnnotationChange() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        setAnnotationSelection([])
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
                return replacing(annotation, text: "\(number)", fontSize: annotation.fontSize)
            }
            letter += 1
            return replacing(annotation, text: alphabeticLabel(for: letter), fontSize: annotation.fontSize)
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

    private func fittedSelectionRect(_ requested: CGRect) -> CGRect {
        var fitted = constrained(requested)
        fitted.size.width = min(max(2, fitted.width), bounds.width)
        fitted.size.height = min(max(2, fitted.height), bounds.height)
        fitted.origin.x = min(max(fitted.minX, bounds.minX), bounds.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, bounds.minY), bounds.maxY - fitted.height)
        return fitted.integral
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
        guard !isCompleting else { return }
        if !textAnnotationField.isHidden { commitTextAnnotation() }
        guard let selection = selectionRect,
              selection.width >= 2,
              selection.height >= 2 else {
            onCancel?()
            return
        }

        if let selectedWindowID, let windowCaptureProvider {
            isCompleting = true
            setControlsEnabled(false)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let capturedWindow = try await windowCaptureProvider(selectedWindowID)
                    guard let rendered = self.renderAnnotations(
                        on: capturedWindow.image,
                        selection: selection
                    ) else {
                        throw ScreenCaptureError.windowUnavailable
                    }
                    self.onSelection?(rendered, output)
                } catch {
                    self.isCompleting = false
                    self.selectedWindowID = nil
                    self.setControlsEnabled(true)
                    let alert = NSAlert(error: error)
                    alert.alertStyle = .warning
                    alert.window.level = .screenSaver
                    alert.runModal()
                }
            }
            return
        }

        guard let cropped = crop(selection) else {
            onCancel?()
            return
        }
        onSelection?(cropped, output)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        for view in toolbarViews {
            (view as? NSControl)?.isEnabled = enabled
        }
        widthField.isEnabled = enabled
        heightField.isEnabled = enabled && !shape.locksAspectRatio
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
        let fieldHeight: CGFloat = 24
        let y = toolbar.minY + 9
        widthField.frame = CGRect(x: toolbar.minX + 38, y: y, width: fieldWidth, height: fieldHeight)
        dimensionSeparator.frame = CGRect(x: toolbar.minX + 104, y: y, width: 18, height: fieldHeight)
        heightField.frame = CGRect(x: toolbar.minX + 122, y: y, width: fieldWidth, height: fieldHeight)
        widthField.isHidden = false
        heightField.isHidden = false
        dimensionSeparator.isHidden = false
        heightField.isEnabled = !shape.locksAspectRatio

        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        if window?.firstResponder !== widthField.currentEditor() && window?.firstResponder !== heightField.currentEditor() {
            widthField.stringValue = "\(Int(selection.width * xScale))"
            heightField.stringValue = "\(Int(selection.height * yScale))"
        }
    }

    @objc private func commitDimensionFields() {
        selectedWindowID = nil
        let parsedWidth = Double(widthField.stringValue)
        let parsedHeight = Double(heightField.stringValue)
        let widthIsValid = parsedWidth.map { $0 >= 2 } ?? false
        let heightIsValid = shape.locksAspectRatio || (parsedHeight.map { $0 >= 2 } ?? false)
        guard let selection = selectionRect,
              let width = parsedWidth,
              widthIsValid,
              heightIsValid else {
            NSSound.beep()
            setDimensionFeedback(
                .error,
                invalidWidth: !widthIsValid,
                invalidHeight: !heightIsValid
            )
            return
        }
        let height = parsedHeight ?? width
        let xScale = CGFloat(capture.image.width) / bounds.width
        let yScale = CGFloat(capture.image.height) / bounds.height
        let targetWidth = CGFloat(width) / xScale
        let targetHeight = (shape.locksAspectRatio ? CGFloat(width) : CGFloat(height)) / yScale
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let requested = CGRect(
            x: center.x - targetWidth / 2,
            y: center.y - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        setPresetButtonTitle(nil)
        fixedSelection = fittedSelectionRect(requested)
        window?.makeFirstResponder(self)
        setDimensionFeedback(.success, resetAfter: 0.9)
        needsDisplay = true
    }
}

extension RegionSelectionView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as AnyObject? === widthField || notification.object as AnyObject? === heightField else { return }
        setDimensionFeedback(.editing)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === widthField || notification.object as AnyObject? === heightField else { return }
        setPresetButtonTitle(nil)
        setDimensionFeedback(.editing)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === textAnnotationField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextAnnotation()
            return true
        }
        return false
    }
}
