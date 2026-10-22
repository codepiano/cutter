import AppKit

@main
@MainActor
enum CutterMain {
    static func main() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let lockURL = directory.appendingPathComponent("Cutter/instance.lock")
            guard let instance = try SingleInstanceLock.acquire(at: lockURL) else { return }
            withExtendedLifetime(instance) {
                let application = NSApplication.shared
                let delegate = AppDelegate()
                application.delegate = delegate
                application.run()
            }
        } catch {
            FileHandle.standardError.write(Data("Cutter 单实例锁初始化失败：\(error)\n".utf8))
        }
    }
}
