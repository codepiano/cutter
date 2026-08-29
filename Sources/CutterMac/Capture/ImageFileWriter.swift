import AppKit
import CoreGraphics
import Foundation

enum ImageFileWriter {
    @MainActor
    static func savePNG(_ image: CGImage) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ImageFileError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Cutter-\(formatter.string(from: Date())).png"
    }
}

enum ImageFileError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "无法将截图编码为 PNG。"
    }
}
