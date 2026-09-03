import CoreGraphics
import Foundation
import CutterCore

enum ScrollCaptureSessionError: LocalizedError, Sendable {
    case noFirstFrame
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noFirstFrame: "首屏截图失败，无法开始滚动截图。"
        case .cancelled: "滚动截图已取消。"
        }
    }
}

actor ScrollCaptureSession {
    enum State: Equatable, Sendable {
        case idle
        case preparing
        case ready
        case capturing
        case paused
        case finishing
        case finished
        case cancelled
    }

    enum FrameOutcome: Equatable, Sendable {
        case ready
        case accepted(addedHeight: Int, totalHeight: Int, segmentCount: Int)
        case duplicate
        case reverse
        case waitingForStableFrame
        case insufficientOverlap
        case ambiguous
        case lowTexture
        case dimensionsChanged
        case captureFailed
        case tooLarge
    }

    struct Snapshot: Equatable, Sendable {
        let state: State
        let outcome: FrameOutcome
        let width: Int
        let height: Int
        let segmentCount: Int
        let canUndo: Bool
    }

    private let sampler: any ScrollFrameSampler
    private var stitcher: VerticalImageStitcher
    private(set) var state: State = .idle
    private enum ProcessingPhase { case waitingForSample, stability, matching }
    private var processingPhase: ProcessingPhase?
    private var generation: UInt64 = 0
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var stableCandidate: CapturedImage?

    init(sampler: any ScrollFrameSampler, configuration: VerticalImageStitcher.Configuration = .init()) {
        self.sampler = sampler
        self.stitcher = VerticalImageStitcher(configuration: configuration)
    }

    func start() async throws -> Snapshot {
        guard state == .idle else { return snapshot(outcome: .ready) }
        let token = generation
        state = .preparing
        processingPhase = .waitingForSample
        defer { finishProcessing() }
        do {
            let frame = try await sampler.sample()
            guard token == generation, state == .preparing else { throw CancellationError() }
            processingPhase = .matching
            let attempt = await process(frame)
            guard token == generation, state == .preparing else { throw CancellationError() }
            let result = attempt.result
            commit(attempt)
            guard case .firstFrame = result else {
                state = .cancelled
                throw ScrollCaptureSessionError.noFirstFrame
            }
            state = .ready
            return snapshot(outcome: .ready)
        } catch {
            state = .cancelled
            await sampler.cancel()
            throw error
        }
    }

    func captureNext() async -> Snapshot {
        guard state == .ready || state == .capturing else { return snapshot(outcome: .ready) }
        guard processingPhase == nil else { return snapshot(outcome: .waitingForStableFrame) }
        let token = generation
        processingPhase = .waitingForSample
        defer { finishProcessing() }
        do {
            let frame = try await sampler.sample()
            guard token == generation, state == .ready || state == .capturing else {
                return snapshot(outcome: .waitingForStableFrame)
            }
            if let candidate = stableCandidate {
                processingPhase = .stability
                let difference = await Task.detached(priority: .userInitiated) {
                    VerticalImageStitcher.adjacentFrameDifference(candidate.image, frame.image)
                }.value
                guard token == generation, state == .ready || state == .capturing else {
                    return snapshot(outcome: .waitingForStableFrame)
                }
                guard let difference, difference <= 0.018 else {
                    stableCandidate = frame
                    return snapshot(outcome: .waitingForStableFrame)
                }
                stableCandidate = nil
            } else {
                stableCandidate = frame
                return snapshot(outcome: .waitingForStableFrame)
            }
            processingPhase = .matching
            let attempt = await process(frame)
            guard token == generation, state == .ready || state == .capturing || state == .finishing else {
                return snapshot(outcome: .waitingForStableFrame)
            }
            let result = attempt.result
            commit(attempt)
            let outcome = map(result)
            if state != .finishing {
                switch outcome {
                case .tooLarge, .dimensionsChanged, .captureFailed:
                    state = .paused
                default:
                    state = .capturing
                }
            }
            return snapshot(outcome: outcome)
        } catch is CancellationError {
            guard token == generation, state != .cancelled else {
                return snapshot(outcome: .waitingForStableFrame)
            }
            state = .cancelled
            return snapshot(outcome: .dimensionsChanged)
        } catch let error as ScreenCaptureError {
            guard token == generation, state != .cancelled, state != .finishing else {
                return snapshot(outcome: .captureFailed)
            }
            stableCandidate = nil
            state = .paused
            return snapshot(outcome: error == .captureGeometryChanged ? .dimensionsChanged : .captureFailed)
        } catch {
            guard token == generation, state != .cancelled, state != .finishing else {
                return snapshot(outcome: .captureFailed)
            }
            stableCandidate = nil
            state = .paused
            return snapshot(outcome: .captureFailed)
        }
    }

    func pause() {
        if state == .ready || state == .capturing { generation &+= 1; stableCandidate = nil; state = .paused }
    }
    func resume() { if state == .paused { generation &+= 1; stableCandidate = nil; state = .capturing } }

    func undoLast() -> Snapshot {
        guard state == .ready || state == .capturing || state == .paused else { return snapshot(outcome: .ready) }
        generation &+= 1
        stableCandidate = nil
        guard stitcher.undoLast() else { return snapshot(outcome: .ready) }
        return snapshot(outcome: .ready)
    }

    func finish() async -> CGImage? {
        guard state != .cancelled, state != .finished else { return nil }
        if state == .finishing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finishWaiters.append(continuation)
            }
            return nil
        }
        // A frame already in matching has been captured and is allowed to
        // settle before the final canvas is made. A sampler call that has not
        // returned yet is invalidated so completion cannot admit a late frame.
        if processingPhase != .matching { generation &+= 1 }
        stableCandidate = nil
        state = .finishing
        await sampler.cancel()
        if processingPhase != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                processingWaiters.append(continuation)
            }
        }
        guard state != .cancelled else {
            resumeFinishWaiters()
            return nil
        }
        let image = stitcher.makeImage()
        state = image == nil ? .cancelled : .finished
        resumeFinishWaiters()
        return image
    }

    func cancel() async {
        guard state != .finished, state != .cancelled else { return }
        generation &+= 1
        stableCandidate = nil
        state = .cancelled
        await sampler.cancel()
    }

    /// Bounded seam preview for the HUD. This intentionally never calls the
    /// full-image compositor while sampling is active.
    func seamThumbnail(maxWidth: Int = 320, tailHeight: Int = 192) -> CGImage? {
        stitcher.makeTailThumbnail(maxWidth: maxWidth, tailHeight: tailHeight)
    }

    private func process(_ frame: CapturedImage) async -> (stitcher: VerticalImageStitcher, result: VerticalImageStitcher.AppendResult) {
        let current = stitcher
        return await Task.detached(priority: .userInitiated) {
            var next = current
            let result = next.append(frame.image)
            return (next, result)
        }.value
    }

    private func commit(_ attempt: (stitcher: VerticalImageStitcher, result: VerticalImageStitcher.AppendResult)) {
        switch attempt.result {
        case .firstFrame, .accepted:
            stitcher = attempt.stitcher
        default:
            break
        }
    }

    private func finishProcessing() {
        processingPhase = nil
        let waiters = processingWaiters
        processingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func map(_ result: VerticalImageStitcher.AppendResult) -> FrameOutcome {
        switch result {
        case .firstFrame: return .ready
        case let .accepted(addedHeight, totalHeight, segmentCount): return .accepted(addedHeight: addedHeight, totalHeight: totalHeight, segmentCount: segmentCount)
        case .duplicate: return .duplicate
        case .reverse: return .reverse
        case .insufficientOverlap: return .insufficientOverlap
        case .ambiguous: return .ambiguous
        case .lowTexture: return .lowTexture
        case .dimensionsChanged: return .dimensionsChanged
        case .tooLarge: return .tooLarge
        }
    }

    private func snapshot(outcome: FrameOutcome) -> Snapshot {
        let progress = stitcher.progress
        return Snapshot(
            state: state,
            outcome: outcome,
            width: progress?.width ?? 0,
            height: progress?.height ?? 0,
            segmentCount: progress?.segmentCount ?? 0,
            canUndo: stitcher.canUndo
        )
    }
}
