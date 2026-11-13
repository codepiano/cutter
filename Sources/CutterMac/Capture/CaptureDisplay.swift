import AppKit
import CoreGraphics

@MainActor
enum CaptureDisplay {
    static func id(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func at(_ point: CGPoint) -> CGDirectDisplayID {
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
        return screen.flatMap { id(for: $0) } ?? CGMainDisplayID()
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { id(for: $0) == displayID }
    }
}
