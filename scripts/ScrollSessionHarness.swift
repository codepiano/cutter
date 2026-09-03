import CoreGraphics
import Foundation

// Deliberately returns an in-flight frame even after cancellation, just as a
// platform API may finish an uncancellable request. The session must discard it.
private actor ControlledSampler: ScrollFrameSampler {
    private var pending: CheckedContinuation<CapturedImage, any Error>?
    func sample() async throws -> CapturedImage {
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil, "Only one capture may be in flight")
            pending = continuation
        }
    }
    func cancel() async {}
    var isWaiting: Bool { pending != nil }
    func deliver(_ frame: CapturedImage) {
        let continuation = pending
        pending = nil
        precondition(continuation != nil)
        continuation?.resume(returning: frame)
    }
    func fail() {
        let continuation = pending
        pending = nil
        precondition(continuation != nil)
        continuation?.resume(throwing: ScreenCaptureError.permissionDenied)
    }
}

@main
private struct ScrollSessionHarness {
    static func main() async throws {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            fatalError("Session regression timed out; an in-flight continuation was not resolved")
        }
        defer { watchdog.cancel() }
        let first = fixture(offset: 0)
        let next = fixture(offset: 17)

        // A cancelled initial request must neither commit pixels nor become ready.
        do {
            let sampler = ControlledSampler()
            let session = ScrollCaptureSession(sampler: sampler)
            let start = Task { try await session.start() }
            await waitForRequest(sampler)
            await session.cancel()
            await sampler.deliver(first)
            do {
                _ = try await start.value
                fatalError("Cancelled start returned success")
            } catch {}
            let snapshot = await session.captureNext()
            expect(snapshot.state == .cancelled && snapshot.height == 0, "cancelled start stays empty")
            let output = await session.finish()
            expect(output == nil, "cancelled start cannot be exported")
        }

        // Cancellation invalidates a frame that returns after the cancel event.
        do {
            let (session, sampler) = try await started(first)
            let capture = Task { await session.captureNext() }
            await waitForRequest(sampler)
            await session.cancel()
            await sampler.deliver(next)
            let snapshot = await capture.value
            expect(snapshot.state == .cancelled, "late frame cannot revive cancelled session")
            expect(snapshot.height == first.image.height, "late frame cannot append after cancellation")
        }

        // A platform error arriving after cancel must not change terminal state.
        do {
            let (session, sampler) = try await started(first)
            let capture = Task { await session.captureNext() }
            await waitForRequest(sampler)
            await session.cancel()
            await sampler.fail()
            let snapshot = await capture.value
            expect(snapshot.state == .cancelled, "late capture error cannot revive cancelled session")
        }

        // Pausing is a user decision; a late callback cannot silently resume it.
        do {
            let (session, sampler) = try await started(first)
            let capture = Task { await session.captureNext() }
            await waitForRequest(sampler)
            await session.pause()
            await sampler.deliver(next)
            let snapshot = await capture.value
            expect(snapshot.state == .paused, "late frame respects pause")
            expect(snapshot.height == first.image.height, "pause prevents late append")
            await session.cancel()
        }

        // Cancel remains authoritative even when finish is waiting on a request.
        do {
            let (session, sampler) = try await started(first)
            let capture = Task { await session.captureNext() }
            await waitForRequest(sampler)
            let finish = Task { await session.finish() }
            await waitForFinishing(session)
            await session.cancel()
            await sampler.deliver(next)
            _ = await capture.value
            let output = await finish.value
            expect(output == nil, "cancel during finish suppresses output")
            let snapshot = await session.captureNext()
            expect(snapshot.state == .cancelled, "finish cannot revive cancelled session")
        }

        // Completion may be requested twice (button and Return). Only one wins.
        do {
            let (session, sampler) = try await started(first)
            let capture = Task { await session.captureNext() }
            await waitForRequest(sampler)
            let finishA = Task { await session.finish() }
            await waitForFinishing(session)
            let finishB = Task { await session.finish() }
            // Let the second request enter the actor while the first is waiting.
            try await Task.sleep(for: .milliseconds(10))
            await sampler.deliver(first)
            _ = await capture.value
            let a = await finishA.value
            let b = await finishB.value
            expect((a == nil ? 0 : 1) + (b == nil ? 0 : 1) == 1, "completion produces exactly one result")
        }
        print("scroll session regression passed: cancelled start, late capture, pause, cancel during finish, single completion")
    }

    private static func started(_ first: CapturedImage) async throws -> (ScrollCaptureSession, ControlledSampler) {
        let sampler = ControlledSampler()
        let session = ScrollCaptureSession(sampler: sampler)
        let start = Task { try await session.start() }
        await waitForRequest(sampler)
        await sampler.deliver(first)
        let snapshot = try await start.value
        expect(snapshot.height == first.image.height, "baseline contains the first frame")
        return (session, sampler)
    }

    private static func waitForRequest(_ sampler: ControlledSampler) async {
        while !(await sampler.isWaiting) { await Task.yield() }
    }

    private static func waitForFinishing(_ session: ScrollCaptureSession) async {
        while await session.state != .finishing { await Task.yield() }
    }

    private static func fixture(offset: Int) -> CapturedImage {
        let width = 96, height = 64
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((x * 17 + (y + offset) * 29 + ((x / 7 + (y + offset) / 5) % 2) * 61) & 255)
                let index = ((height - 1 - y) * width + x) * 4
                bytes[index] = value
                bytes[index + 1] = value ^ 0x35
                bytes[index + 2] = value ^ 0x7a
                bytes[index + 3] = 255
            }
        }
        return CapturedImage(image: context.makeImage()!, displayID: 1, scaleFactor: 1)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
