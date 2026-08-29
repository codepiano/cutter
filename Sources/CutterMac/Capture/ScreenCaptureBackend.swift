import CoreGraphics
import Foundation

struct CapturedImage: @unchecked Sendable {
    let image: CGImage
    let displayID: CGDirectDisplayID
    let scaleFactor: CGFloat
}

protocol ScreenCaptureBackend: Sendable {
    func capturePrimaryDisplay(includeCursor: Bool) async throws -> CapturedImage
}

enum ScreenCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case primaryDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Cutter 没有屏幕录制权限。请在系统设置的“隐私与安全性”中允许后重试。"
        case .primaryDisplayUnavailable:
            "没有找到可截取的主显示器。"
        }
    }
}
