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
    func prepareScrollSampler(
        displayID: CGDirectDisplayID,
        region: CGRect,
        includeCursor: Bool
    ) async throws -> any ScrollFrameSampler
}

protocol ScrollFrameSampler: Sendable {
    func sample() async throws -> CapturedImage
    func cancel() async
}

enum ScreenCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case primaryDisplayUnavailable
    case windowUnavailable
    case captureGeometryChanged
    case captureFilterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Cutter 没有屏幕录制权限。请在系统设置的“隐私与安全性”中允许后重试。"
        case .primaryDisplayUnavailable:
            "没有找到可截取的主显示器。"
        case .windowUnavailable:
            "目标窗口已经关闭或不再可截取。"
        case .captureGeometryChanged:
            "显示器或捕获比例发生变化，已停止滚动截图；已有结果仍可完成。"
        case .captureFilterUnavailable:
            "无法可靠排除 Cutter 自身窗口，已停止滚动截图；请重试。"
        }
    }
}
