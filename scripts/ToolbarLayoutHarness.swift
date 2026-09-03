import AppKit
import CoreGraphics

@main
@MainActor
struct ToolbarLayoutHarness {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (width, height, nearFull) in [(1440, 900, false), (1024, 768, true), (800, 600, false), (640, 600, false)] {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.gray.cgColor)
            context.fill(frame)
            let view = RegionSelectionView(frame: frame,
                capture: CapturedImage(image: context.makeImage()!, displayID: CGMainDisplayID(), scaleFactor: 1),
                defaultOutput: .copy)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            let from = nearFull ? CGPoint(x: 10, y: 10) : CGPoint(x: 60, y: 220)
            let to = nearFull ? CGPoint(x: width - 10, y: height - 10) : CGPoint(x: min(width - 40, 560), y: height - 80)
            drag(view, window: window, from: from, to: to)
            try verifyAndRender(view, output: output.appendingPathComponent("toolbar-\(width).png"))
            let shapeLabels = ["矩形选区", "正方形选区", "圆形选区", "邮票选区"]
            for label in shapeLabels {
                let button = view.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }!
                precondition(button.title.isEmpty && button.image != nil && button.imagePosition == .imageOnly, "Shape must be an icon: \(label)")
            }
            let tools = view.subviews.compactMap { $0 as? NSButton }.filter { $0.imagePosition == .imageOnly }
            precondition(tools.count == 17 && tools.allSatisfy { $0.image != nil }, "All native tool symbols must resolve")
            let number = tools.first { $0.accessibilityLabel() == "数字" }!
            number.performClick(nil)
            view.mouseDown(with: event(.leftMouseDown, point: CGPoint(x: 300, y: 300), window: window))
            view.mouseUp(with: event(.leftMouseUp, point: CGPoint(x: 300, y: 300), window: window))
            try verifyAndRender(view, output: output.appendingPathComponent("toolbar-\(width)-context.png"))
            precondition(view.subviews.compactMap { $0 as? NSButton }.contains { !$0.isHidden && $0.accessibilityLabel() == "复制选中标注" })
            view.closeAuxiliaryPanels()
            window.close()
        }
        print("Toolbar layout passed: 1440/1024/800/640 pt, near-full selection, annotation context, all 17 icons, no overlapping controls")
    }

    private static func event(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func drag(_ view: RegionSelectionView, window: NSWindow, from: CGPoint, to: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, point: from, window: window))
        view.mouseDragged(with: event(.leftMouseDragged, point: to, window: window))
        view.mouseUp(with: event(.leftMouseUp, point: to, window: window))
    }

    private static func verifyAndRender(_ view: RegionSelectionView, output: URL) throws {
        view.needsDisplay = true
        let full = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: full)
        let controls = view.subviews.compactMap { $0 as? NSControl }.filter { !$0.isHidden }
        precondition(!controls.isEmpty)
        for (index, control) in controls.enumerated() {
            precondition(view.bounds.contains(control.frame), "Outside viewport: \(control.accessibilityLabel() ?? "?") \(control.frame)")
            for other in controls.dropFirst(index + 1) {
                precondition(!control.frame.intersects(other.frame),
                    "Overlap: \(control.accessibilityLabel() ?? "?") / \(other.accessibilityLabel() ?? "?")")
            }
        }
        let region = controls.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -10, dy: -10).intersection(view.bounds)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: region)!
        view.cacheDisplay(in: region, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
    }
}
