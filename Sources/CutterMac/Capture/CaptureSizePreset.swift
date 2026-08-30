import Foundation

struct CaptureSizePreset: Codable, Hashable {
    static let supportedRange = 2...32_768
    static let builtIns: [CaptureSizePreset] = [
        CaptureSizePreset(width: 200, height: 200)!,
        CaptureSizePreset(width: 400, height: 400)!,
        CaptureSizePreset(width: 800, height: 600)!,
        CaptureSizePreset(width: 1_280, height: 720)!
    ]

    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard Self.supportedRange.contains(width), Self.supportedRange.contains(height) else { return nil }
        self.width = width
        self.height = height
    }

    var title: String { "\(width) × \(height)" }
    var compactTitle: String { "\(width)×\(height)" }
    var identifier: String { "\(width)x\(height)" }

    var isValid: Bool {
        Self.supportedRange.contains(width) && Self.supportedRange.contains(height)
    }
}

final class CaptureSizePresetStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "capture.customSizePresets") {
        self.defaults = defaults
        self.key = key
    }

    var customPresets: [CaptureSizePreset] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CaptureSizePreset].self, from: data) else {
            return []
        }
        var seen = Set<CaptureSizePreset>()
        return decoded.filter { preset in
            preset.isValid && !CaptureSizePreset.builtIns.contains(preset) && seen.insert(preset).inserted
        }
    }

    @discardableResult
    func add(_ preset: CaptureSizePreset) -> Bool {
        guard preset.isValid,
              !CaptureSizePreset.builtIns.contains(preset) else { return false }
        var presets = customPresets
        guard !presets.contains(preset) else { return false }
        presets.append(preset)
        save(presets)
        return true
    }

    @discardableResult
    func remove(_ preset: CaptureSizePreset) -> Bool {
        let existing = customPresets
        let updated = existing.filter { $0 != preset }
        guard updated.count != existing.count else { return false }
        save(updated)
        return true
    }

    private func save(_ presets: [CaptureSizePreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }
}
