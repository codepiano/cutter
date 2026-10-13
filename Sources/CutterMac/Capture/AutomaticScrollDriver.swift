import AppKit
import CoreGraphics

enum AutomaticScrollError: LocalizedError, Equatable {
    case permissionRequired
    case targetUnavailable
    case targetChanged
    case eventUnavailable
    case pointerMoved

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "自动滚动需要辅助功能权限；点击“授权…”后继续，或切换手动模式"
        case .targetUnavailable: "未找到目标窗口；请重新框选目标应用的滚动内容，或切换手动模式"
        case .targetChanged: "目标窗口被遮挡、移动或失去焦点；恢复原窗口后继续"
        case .eventUnavailable: "无法发送滚动操作；可切换手动模式"
        case .pointerMoved: "鼠标已移开，自动滚动已暂停；点击继续重试"
        }
    }
}

@MainActor
protocol AutomaticScrollDriving: AnyObject {
    func prepare() throws
    func scrollDown(points: Int32) throws
    func requestPermission()
    func stop()
}

/// WindowServer routes scroll events using the actual pointer. Keep it at one
/// validated point while active, and restore it on stop if the user hasn't moved it.
@MainActor
final class AutomaticScrollDriver: AutomaticScrollDriving {
    private struct Target: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let bounds: CGRect
    }

    private let location: CGPoint
    private let displayBounds: CGRect
    private var target: Target?
    private var originalPointer: CGPoint?

    init(displayID: CGDirectDisplayID, region: CGRect) {
        let bounds = CGDisplayBounds(displayID)
        displayBounds = bounds
        location = CGPoint(x: bounds.minX + region.midX, y: bounds.minY + bounds.height - region.midY)
        target = windowAtLocation()
    }

    func prepare() throws {
        guard CGPreflightPostEventAccess() else { throw AutomaticScrollError.permissionRequired }
        guard let target else { throw AutomaticScrollError.targetUnavailable }
        let appKitPoint = CGPoint(x: location.x, y: CGDisplayBounds(CGMainDisplayID()).height - location.y)
        guard !NSApp.windows.contains(where: { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(appKitPoint) }) else {
            throw AutomaticScrollError.targetChanged
        }
        guard let current = windowAtLocation(), target == current else { throw AutomaticScrollError.targetChanged }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid else {
            throw AutomaticScrollError.targetChanged
        }
        if originalPointer != nil, !pointerIsAtAnchor { throw AutomaticScrollError.pointerMoved }
    }

    func scrollDown(points: Int32) throws {
        try prepare()
        guard let target, let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: -max(1, points), wheel2: 0, wheel3: 0
        ) else { throw AutomaticScrollError.eventUnavailable }
        event.location = location
        event.flags = []
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
        if originalPointer == nil {
            originalPointer = CGEvent(source: nil)?.location
            guard CGWarpMouseCursorPosition(location) == .success else {
                originalPointer = nil
                throw AutomaticScrollError.eventUnavailable
            }
        }
        // Let WindowServer resolve the window at this validated point. Posting
        // straight to a PID yields windowNumber 0 in AppKit scroll events.
        event.post(tap: .cghidEventTap)
    }

    func requestPermission() { _ = CGRequestPostEventAccess() }

    func stop() {
        if let originalPointer, pointerIsAtAnchor { _ = CGWarpMouseCursorPosition(originalPointer) }
        originalPointer = nil
    }

    private var pointerIsAtAnchor: Bool {
        guard let point = CGEvent(source: nil)?.location else { return false }
        return abs(point.x - location.x) <= 2 && abs(point.y - location.y) <= 2
    }

    private func windowAtLocation() -> Target? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds), bounds.contains(location)
            else { continue }
            // Dock publishes a full-display transparent compositor surface at
            // layer 20. It is not an occluding popup or an input destination.
            if layer == 20, bounds == displayBounds,
               NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" { continue }
            // A menu, popup or other overlay blocks automatic input as well.
            guard layer == 0, let id = window[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return Target(pid: pid, windowID: id, bounds: bounds)
        }
        return nil
    }
}

/// A closed loop: only a matched stable frame permits the next scroll. A
/// duplicate is retried slowly; it is never taken as proof of page bottom.
struct AutomaticScrollPacer {
    enum Decision: Equatable {
        case wait
        case scroll
        case pause(String)
    }

    private var lastScroll: TimeInterval?
    private var unchangedAttempts = 0
    private var stabilityStarted: TimeInterval?

    mutating func reset() { lastScroll = nil; unchangedAttempts = 0; stabilityStarted = nil }

    mutating func next(for outcome: ScrollCaptureSession.FrameOutcome, now: TimeInterval) -> Decision {
        switch outcome {
        case .ready, .accepted:
            unchangedAttempts = 0
            return .scroll
        case .duplicate:
            guard let lastScroll else { return .scroll }
            guard now - lastScroll >= 2 else { return .wait }
            unchangedAttempts += 1
            return unchangedAttempts >= 3
                ? .pause("多次滚动后画面未变化，可能已到底；可完成或继续重试") : .scroll
        case .waitingForStableFrame:
            if stabilityStarted == nil { stabilityStarted = now }
            return now - (lastScroll ?? stabilityStarted ?? now) >= 8
                ? .pause("画面持续变化，已暂停；等待加载完成后继续") : .wait
        case .reverse, .insufficientOverlap, .ambiguous, .lowTexture:
            return .pause("无法可靠衔接，已暂停；切换手动模式，往回滚一点后继续")
        case .dimensionsChanged, .captureFailed, .tooLarge:
            return .wait // The capture session itself pauses these failures.
        }
    }

    mutating func didScroll(at now: TimeInterval) { lastScroll = now; stabilityStarted = nil }
}
