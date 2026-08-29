import AppKit
import CoreGraphics
import Foundation

enum ImageClipboard {
    @MainActor
    static func copy(_ image: CGImage, scaleFactor: CGFloat) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let resolvedScale = max(scaleFactor, 1)
        let nativeImage = NSImage(
            cgImage: image,
            size: NSSize(
                width: CGFloat(image.width) / resolvedScale,
                height: CGFloat(image.height) / resolvedScale
            )
        )
        guard pasteboard.writeObjects([nativeImage]) else {
            throw ClipboardError.writeFailed
        }
    }
}

enum ClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "无法将截图写入剪贴板。"
    }
}
