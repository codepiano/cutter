import Foundation

struct CaptureSettings {
    enum Output: String {
        case copy
        case save
        case copyAndSave
    }

    var includeCursor: Bool
    var output: Output

    static var current: CaptureSettings {
        let defaults = UserDefaults.standard
        let output = Output(rawValue: defaults.string(forKey: Keys.output) ?? "copy") ?? .copy
        return CaptureSettings(
            includeCursor: defaults.bool(forKey: Keys.includeCursor),
            output: output
        )
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(includeCursor, forKey: Keys.includeCursor)
        defaults.set(output.rawValue, forKey: Keys.output)
    }

    private enum Keys {
        static let includeCursor = "capture.includeCursor"
        static let output = "capture.output"
    }
}
