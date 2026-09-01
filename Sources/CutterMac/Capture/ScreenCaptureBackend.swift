import CoreGraphics
import Foundation

struct CapturedImage: @unchecked Sendable {
    let image: CGImage
    let displayID: CGDirectDisplayID
    let scaleFactor: CGFloat
}

struct CapturableWindow: Sendable, Identifiable {
    let id: CGWindowID
    let frame: CGRect
    let displayID: CGDirectDisplayID
    let title: String
    let ownerName: String
}

struct CaptureWorkspace: @unchecked Sendable {
    let display: CapturedImage
    let windows: [CapturableWindow]
}

protocol ScreenCaptureBackend: Sendable {
    func preparePrimaryDisplay(includeCursor: Bool) async throws -> CaptureWorkspace
    func captureWindow(id: CGWindowID, includeCursor: Bool) async throws -> CapturedImage
}

enum ScreenCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case primaryDisplayUnavailable
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Cutter 没有屏幕录制权限。请在系统设置的“隐私与安全性”中允许后重试。"
        case .primaryDisplayUnavailable:
            "没有找到可截取的主显示器。"
        case .windowUnavailable:
            "目标窗口已经关闭或不再可截取。"
        }
    }
}
