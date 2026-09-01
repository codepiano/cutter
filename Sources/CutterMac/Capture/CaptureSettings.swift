import Foundation

struct CaptureSettings {
    enum Shape: String {
        case rectangle
        case square
        case circle
        case stamp

        var locksAspectRatio: Bool {
            self == .square || self == .circle
        }
    }

    enum Output: String {
        case copy
        case save
        case copyAndSave
    }

    enum Delay: Int, CaseIterable {
        case immediate = 0
        case threeSeconds = 3
        case fiveSeconds = 5
        case tenSeconds = 10

        var title: String {
            switch self {
            case .immediate: "立即"
            case .threeSeconds: "3 秒"
            case .fiveSeconds: "5 秒"
            case .tenSeconds: "10 秒"
            }
        }
    }

    var includeCursor: Bool
    var output: Output
    var downloadDirectory: URL
    var delay: Delay

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
            downloadDirectory: configuredDirectory,
            delay: Delay(rawValue: defaults.integer(forKey: Keys.delaySeconds)) ?? .immediate
        )
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(includeCursor, forKey: Keys.includeCursor)
        defaults.set(output.rawValue, forKey: Keys.output)
        defaults.set(downloadDirectory.path, forKey: Keys.downloadDirectory)
        defaults.set(delay.rawValue, forKey: Keys.delaySeconds)
    }

    private enum Keys {
        static let includeCursor = "capture.includeCursor"
        static let output = "capture.output"
        static let downloadDirectory = "capture.downloadDirectory"
        static let delaySeconds = "capture.delaySeconds"
    }
}
