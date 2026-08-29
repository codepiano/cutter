import AppKit
import CoreGraphics
import Foundation

enum ImageFileWriter {
    @MainActor
    static func savePNG(_ image: CGImage, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(defaultFileName())
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(defaultFileName(suffix: suffix))
            suffix += 1
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ImageFileError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func defaultFileName(suffix: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "Cutter-\(formatter.string(from: Date()))"
        return "\(base)\(suffix.map { "-\($0)" } ?? "").png"
    }
}

enum ImageFileError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "无法将截图编码为 PNG。"
    }
}
