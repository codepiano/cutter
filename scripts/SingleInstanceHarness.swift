import AppKit
import Carbon.HIToolbox

@main
@MainActor
private struct SingleInstanceHarness {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count > 1 {
            if args[1] == "lock" {
                let lock = try SingleInstanceLock.acquire(at: URL(fileURLWithPath: args[2]))
                precondition((lock != nil) == (args[3] == "true"), "Unexpected cross-process lock result")
                withExtendedLifetime(lock) {}
            } else if args[1] == "exit-with-lock" {
                let lock = try SingleInstanceLock.acquire(at: URL(fileURLWithPath: args[2]))
                precondition(lock != nil)
                withExtendedLifetime(lock) { exit(0) } // No Swift deinit; kernel releases the lock.
            } else {
                _ = NSApplication.shared
                let ref = register(options: UInt32(args[2])!)
                precondition((ref != nil) == (args[3] == "true"), "Unexpected cross-process hotkey result")
                if let ref { UnregisterEventHotKey(ref) }
            }
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cutter-instance-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("instance.lock")
        var lock = try SingleInstanceLock.acquire(at: file)
        precondition(lock != nil)
        try child(["lock", file.path, "false"])
        withExtendedLifetime(lock) {}
        lock = nil
        try child(["lock", file.path, "true"])
        try child(["exit-with-lock", file.path])
        lock = try SingleInstanceLock.acquire(at: file)
        precondition(lock != nil, "Process exit must release the lock without removing the file")
        withExtendedLifetime(lock) {}
        print("Single-instance regression passed: contention, clean exit, abrupt exit, stale file reuse")

        _ = NSApplication.shared
        // A spare chord avoids touching Cutter's live Option-Command-2 binding.
        let shared = register(options: 0)!
        try child(["hotkey", "0", "true"])
        UnregisterEventHotKey(shared)
        let exclusive = register(options: GlobalShortcutService.registrationOptions)!
        try child(["hotkey", String(GlobalShortcutService.registrationOptions), "false"])
        UnregisterEventHotKey(exclusive)
        try child(["hotkey", String(GlobalShortcutService.registrationOptions), "true"])
        print("Hotkey regression passed: reproduced dual non-exclusive registration; exclusive binding rejects duplicate and releases on exit")
    }

    private static func child(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Child failed: \(arguments)")
    }

    private static func register(options: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(kVK_F20), UInt32(cmdKey | controlKey | optionKey), EventHotKeyID(signature: 0x43545453, id: 1), GetApplicationEventTarget(), options, &ref)
        return result == noErr ? ref : nil
    }
}
