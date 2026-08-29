import Foundation

struct CaptureSettings {
    enum Shape: String {
        case rectangle
        case square
        case circle
    }

    enum Output: String {
        case copy
        case save
        case copyAndSave
    }

    var includeCursor: Bool
    var output: Output
    var downloadDirectory: URL

    static var current: CaptureSettings {
        let defaults = UserDefaults.standard
        let output = Output(rawValue: defaults.string(forKey: Keys.output) ?? "copy") ?? .copy
        let defaultDirectory = (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures"))
            .appendingPathComponent("Cutter", isDirectory: true)
        let oldDefaultDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let configuredDirectory = defaults.string(forKey: Keys.downloadDirectory)
            .map(URL.init(fileURLWithPath:))
            .flatMap { $0.path == oldDefaultDirectory.path ? nil : $0 }
            ?? defaultDirectory
        return CaptureSettings(
            includeCursor: defaults.bool(forKey: Keys.includeCursor),
            output: output,
            downloadDirectory: configuredDirectory
        )
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(includeCursor, forKey: Keys.includeCursor)
        defaults.set(output.rawValue, forKey: Keys.output)
        defaults.set(downloadDirectory.path, forKey: Keys.downloadDirectory)
    }

    private enum Keys {
        static let includeCursor = "capture.includeCursor"
        static let output = "capture.output"
        static let downloadDirectory = "capture.downloadDirectory"
    }
}
