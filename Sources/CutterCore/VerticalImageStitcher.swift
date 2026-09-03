import CoreGraphics
import Foundation

/// A bounded, platform-independent vertical stitcher.
///
/// The first and latest accepted frame are kept in original pixel resolution
/// for matching. Newly exposed rows are retained as compact strips; the final
/// canvas is allocated once, when `makeImage()` is called.
public struct VerticalImageStitcher: Sendable {
    public struct Configuration: Sendable {
        public var minimumOverlapFraction: Double = 0.25
        public var maximumShiftFraction: Double = 0.78
        public var maximumHeight: Int = 32_768
        public var maximumPixels: Int64 = 40_000_000
        public var memoryBudgetBytes: Int64 = 384 * 1024 * 1024

        public init() {}
    }

    public enum AppendResult: Equatable, Sendable {
        case firstFrame(width: Int, height: Int)
        case accepted(addedHeight: Int, totalHeight: Int, segmentCount: Int)
        case duplicate
        case reverse
        case insufficientOverlap
        case ambiguous
        case lowTexture
        case dimensionsChanged
        case tooLarge
    }

    public struct Progress: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let segmentCount: Int
        public let memoryBytes: Int64
    }

    fileprivate struct PixelBuffer: Sendable {
        let width: Int
        let height: Int
        let bytes: [UInt8] // RGBA, top-left origin

        var byteCount: Int64 { Int64(bytes.count) }

        func luminance(x: Int, y: Int) -> Double {
            let i = (y * width + x) * 4
            return (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
        }
    }

    private struct Strip: Sendable {
        let y: Int
        let height: Int
        let bytes: [UInt8]
        var byteCount: Int64 { Int64(bytes.count) }
    }

    private struct Candidate {
        let shift: Int
        let error: Double
        let support: Int
        let texture: Double
    }

    public let configuration: Configuration
    private var firstFrame: PixelBuffer?
    private var lastFrame: PixelBuffer?
    private var strips: [Strip] = []
    private var totalHeight = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var progress: Progress? {
        guard let first = firstFrame else { return nil }
        return Progress(
            width: first.width,
            height: totalHeight,
            segmentCount: strips.count + 1,
            memoryBytes: memoryBytes
        )
    }

    /// Number of frames represented by the result. The initial frame counts
    /// as one; `canUndo` remains separate because the first frame is not undoable.
    public var segmentCount: Int { firstFrame == nil ? 0 : strips.count + 1 }
    public var canUndo: Bool { !strips.isEmpty }
    public var isEmpty: Bool { firstFrame == nil }
    public var memoryBytes: Int64 {
        Int64((firstFrame?.bytes.count ?? 0) + (lastFrame?.bytes.count ?? 0))
            + Int64(strips.reduce(0) { $0 + $1.bytes.count })
    }

    public mutating func append(_ image: CGImage) -> AppendResult {
        guard Self.validDimensions(width: image.width, height: image.height),
              let byteCount = pixelByteCount(width: image.width, height: image.height),
              byteCount <= configuration.memoryBudgetBytes else { return .tooLarge }
        guard let frame = PixelBuffer(image: image) else { return .dimensionsChanged }
        return append(frame)
    }

    /// This overload makes deterministic fixtures inexpensive while keeping
    /// the public CGImage API used by the capture session.
    public mutating func appendRGBA(width: Int, height: Int, bytes: [UInt8]) -> AppendResult {
        guard width > 0, height > 0,
              width <= Int.max / 4,
              height <= Int.max / (width * 4),
              bytes.count == width * height * 4 else { return .dimensionsChanged }
        return append(PixelBuffer(width: width, height: height, bytes: bytes))
    }

    private mutating func append(_ frame: PixelBuffer) -> AppendResult {
        if firstFrame == nil {
            // Resident first frame + final canvas + one encoded/export buffer.
            guard withinLimits(width: frame.width, height: frame.height),
                  frame.byteCount <= configuration.memoryBudgetBytes / 3,
                  fitsMemory(adding: frame.byteCount) else {
                return .tooLarge
            }
            firstFrame = frame
            lastFrame = nil
            totalHeight = frame.height
            return .firstFrame(width: frame.width, height: frame.height)
        }
        guard let first = firstFrame,
              frame.width == first.width, frame.height == first.height else {
            return .dimensionsChanged
        }
        let previous = lastFrame ?? first
        if nearEqualWholeFrame(previous, frame) { return .duplicate }

        if isReverse(previous: previous, next: frame) { return .reverse }

        let candidates = candidates(previous: previous, next: frame)
        guard !candidates.isEmpty else { return .lowTexture }
        guard let best = candidates.first else { return .insufficientOverlap }

        // A matching overlap must contain enough independent horizontal bands.
        // This rejects a fixed header, a blank region, and repeated table rows.
        guard best.texture >= 0.012 else { return .lowTexture }
        guard best.support >= 2 else { return .insufficientOverlap }
        if let second = candidates.dropFirst().first,
           second.error - best.error < max(0.006, best.error * 0.16) {
            return .ambiguous
        }

        // `shift` is the number of newly exposed rows after a downward scroll.
        // The overlap is the old frame's bottom / new frame's top; append the
        // new frame's bottom `shift` rows only.
        let addedHeight = best.shift
        guard addedHeight > 0 else { return .duplicate }
        guard withinLimits(width: frame.width, height: totalHeight + addedHeight) else { return .tooLarge }
        let overlapHeight = frame.height - best.shift
        guard frame.width <= Int.max / 4,
              addedHeight <= Int.max / (frame.width * 4) else { return .tooLarge }
        let addedBytes = Int64(addedHeight * frame.width * 4)
        guard memoryBytes <= configuration.memoryBudgetBytes,
              frame.byteCount <= configuration.memoryBudgetBytes - memoryBytes,
              addedBytes <= configuration.memoryBudgetBytes - memoryBytes - frame.byteCount,
              let finalBytes = pixelByteCount(width: frame.width, height: totalHeight + addedHeight),
              finalBytes <= (configuration.memoryBudgetBytes - memoryBytes - frame.byteCount - addedBytes) / 2 else { return .tooLarge }
        let stripStart = overlapHeight * frame.width * 4
        let stripBytes = Array(frame.bytes[stripStart..<frame.bytes.count])
        guard Int64(stripBytes.count) == addedBytes else { return .dimensionsChanged }

        strips.append(Strip(y: totalHeight, height: addedHeight, bytes: stripBytes))
        lastFrame = frame
        totalHeight += addedHeight
        return .accepted(addedHeight: addedHeight, totalHeight: totalHeight, segmentCount: strips.count + 1)
    }

    @discardableResult
    public mutating func undoLast() -> Bool {
        guard !strips.isEmpty, let first = firstFrame else { return false }
        guard let strip = strips.popLast() else { return false }
        totalHeight -= strip.height
        lastFrame = strips.isEmpty ? nil : reconstructTail(frameHeight: first.height)
        return true
    }

    public func makeImage() -> CGImage? {
        guard let first = firstFrame,
              totalHeight > 0,
              first.width <= Int.max / 4,
              totalHeight <= Int.max / (first.width * 4),
              memoryBytes <= configuration.memoryBudgetBytes,
              Int64(first.width * totalHeight * 4) <= (configuration.memoryBudgetBytes - memoryBytes) / 2,
              let context = CGContext(
                data: nil,
                width: first.width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: first.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let rowBytes = first.width * 4
        for y in 0..<first.height {
            copyRow(first.bytes, sourceRow: y, to: context, destinationRow: y, rowBytes: rowBytes)
        }
        for strip in strips {
            for row in 0..<strip.height {
                copyRow(strip.bytes, sourceRow: row, to: context, destinationRow: strip.y + row, rowBytes: rowBytes)
            }
        }
        return context.makeImage()
    }

    /// Returns only the most recent bounded tail for a live HUD seam preview.
    /// It never allocates the full long image.
    public func makeTailThumbnail(maxWidth: Int = 320, tailHeight: Int = 192) -> CGImage? {
        guard firstFrame != nil, let tail = reconstructTail(frameHeight: min(tailHeight, totalHeight)), maxWidth > 0 else { return nil }
        let source = makeImage(from: tail)
        guard let source else { return nil }
        let scale = min(1, CGFloat(maxWidth) / CGFloat(source.width))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func adjacentFrameDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double? {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              validDimensions(width: lhs.width, height: lhs.height),
              let left = PixelBuffer(image: lhs), let right = PixelBuffer(image: rhs) else { return nil }
        let stepX = max(1, left.width / 72)
        let stepY = max(1, left.height / 120)
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: left.height, by: stepY) {
            for x in stride(from: 0, to: left.width, by: stepX) {
                total += abs(left.luminance(x: x, y: y) - right.luminance(x: x, y: y))
                count += 1
            }
        }
        return count == 0 ? nil : total / Double(count)
    }

    private func makeImage(from buffer: PixelBuffer) -> CGImage? {
        guard buffer.width <= Int.max / 4,
              buffer.height <= Int.max / (buffer.width * 4),
              let context = CGContext(data: nil, width: buffer.width, height: buffer.height,
                                       bitsPerComponent: 8, bytesPerRow: buffer.width * 4,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rowBytes = buffer.width * 4
        for y in 0..<buffer.height {
            copyRow(buffer.bytes, sourceRow: y, to: context, destinationRow: y, rowBytes: rowBytes)
        }
        return context.makeImage()
    }

    private func copyRow(_ bytes: [UInt8], sourceRow: Int, to context: CGContext, destinationRow: Int, rowBytes: Int) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.data?.advanced(by: destinationRow * rowBytes)
                .copyMemory(from: base.advanced(by: sourceRow * rowBytes), byteCount: rowBytes)
        }
    }

    private func withinLimits(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, height <= configuration.maximumHeight,
              width <= Int.max / 4, height <= Int.max / (width * 4) else { return false }
        return Int64(width) <= configuration.maximumPixels / Int64(height)
    }

    private static func validDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= Int.max / 4 && height <= Int.max / (width * 4)
    }

    private func pixelByteCount(width: Int, height: Int) -> Int64? {
        guard Self.validDimensions(width: width, height: height) else { return nil }
        return Int64(width * height * 4)
    }

    private func fitsMemory(adding bytes: Int64) -> Bool {
        bytes >= 0 && bytes <= configuration.memoryBudgetBytes && memoryBytes <= configuration.memoryBudgetBytes - bytes
    }

    private func nearEqualWholeFrame(_ lhs: PixelBuffer, _ rhs: PixelBuffer) -> Bool {
        var total = 0.0
        var count = 0
        let stepX = max(1, lhs.width / 48)
        let stepY = max(1, lhs.height / 48)
        for y in stride(from: 0, to: lhs.height, by: stepY) {
            for x in stride(from: 0, to: lhs.width, by: stepX) {
                total += pixelError(lhs, rhs, x: x, lhsY: y, rhsY: y)
                count += 1
            }
        }
        return count > 0 && total / Double(count) < 0.009
    }

    private func reconstructTail(frameHeight: Int) -> PixelBuffer? {
        guard let first = firstFrame,
              frameHeight > 0,
              totalHeight >= frameHeight,
              first.width <= Int.max / 4,
              frameHeight <= Int.max / (first.width * 4) else { return nil }
        let rowBytes = first.width * 4
        var bytes = [UInt8](repeating: 0, count: frameHeight * rowBytes)
        let startY = totalHeight - frameHeight
        for row in 0..<frameHeight {
            let outputY = startY + row
            let source: ArraySlice<UInt8>
            if outputY < first.height {
                source = first.bytes[(outputY * rowBytes)..<((outputY + 1) * rowBytes)]
            } else if let strip = strips.last(where: { $0.y <= outputY && outputY < $0.y + $0.height }) {
                let stripY = outputY - strip.y
                source = strip.bytes[(stripY * rowBytes)..<((stripY + 1) * rowBytes)]
            } else {
                return nil
            }
            bytes.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: source)
        }
        return PixelBuffer(width: first.width, height: frameHeight, bytes: bytes)
    }

    private func isReverse(previous: PixelBuffer, next: PixelBuffer) -> Bool {
        let minOverlap = max(8, Int(Double(previous.height) * configuration.minimumOverlapFraction))
        let maxShift = min(previous.height - minOverlap, Int(Double(previous.height) * configuration.maximumShiftFraction))
        let step = max(1, min(4, previous.height / 180))
        var bestShift: Int?
        var bestError = Double.greatestFiniteMagnitude
        for shift in stride(from: 1, through: maxShift, by: step) {
            let overlap = previous.height - shift
            let error = overlapError(previous: previous, next: next, previousStart: 0, nextStart: shift)
            let texture = overlapTexture(previous: previous, start: 0, height: overlap)
            if texture >= 0.012 && error < bestError { bestError = error; bestShift = shift }
        }
        guard let bestShift else { return false }
        for shift in max(1, bestShift - step)...min(maxShift, bestShift + step) {
            let overlap = previous.height - shift
            let error = overlapError(previous: previous, next: next, previousStart: 0, nextStart: shift)
            let texture = overlapTexture(previous: previous, start: 0, height: overlap)
            if texture >= 0.012 && error < 0.018 { return true }
        }
        return false
    }

    private func overlapError(previous: PixelBuffer, next: PixelBuffer, previousStart: Int, nextStart: Int) -> Double {
        let height = min(previous.height - previousStart, next.height - nextStart)
        guard height > 0 else { return 1 }
        let stepY = max(1, height / 120)
        let stepX = max(1, previous.width / 72)
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: previous.width, by: stepX) {
                total += pixelError(previous, next, x: x, lhsY: previousStart + y, rhsY: nextStart + y)
                count += 1
            }
        }
        return count == 0 ? 1 : total / Double(count)
    }

    private func overlapTexture(previous: PixelBuffer, start: Int, height: Int) -> Double {
        let stepY = max(1, height / 120)
        let stepX = max(1, previous.width / 72)
        var values: [Double] = []
        for y in stride(from: start, to: min(previous.height, start + height), by: stepY) {
            for x in stride(from: 0, to: previous.width, by: stepX) { values.append(previous.luminance(x: x, y: y)) }
        }
        return textureVariance(values)
    }

    private func candidates(previous: PixelBuffer, next: PixelBuffer) -> [Candidate] {
        let minOverlap = max(8, Int(Double(previous.height) * configuration.minimumOverlapFraction))
        let maxShift = min(previous.height - minOverlap, Int(Double(previous.height) * configuration.maximumShiftFraction))
        guard maxShift >= 4 else { return [] }
        let stepY = max(1, previous.height / 120)
        let stepX = max(1, previous.width / 72)
        let bandCount = 7
        let bandHeight = max(4, previous.height / 18)
        var result: [Candidate] = []

        let coarseStep = max(1, min(4, previous.height / 180))
        for shift in stride(from: 1, through: maxShift, by: coarseStep) {
            let overlapHeight = previous.height - shift
            guard overlapHeight >= minOverlap else { continue }
            var bandErrors: [Double] = []
            var allValues: [Double] = []
            for band in 0..<bandCount {
                let ratio = Double(band + 1) / Double(bandCount + 1)
                let center = min(previous.height - bandHeight / 2 - 1, max(bandHeight / 2, Int(Double(overlapHeight) * ratio)))
                var error = 0.0
                var count = 0
                for y in stride(from: max(0, center - bandHeight / 2), to: min(overlapHeight, center + bandHeight / 2), by: stepY) {
                    for x in stride(from: 0, to: previous.width, by: stepX) {
                        let value = pixelError(previous, next, x: x, lhsY: y + shift, rhsY: y)
                        error += value
                        allValues.append(previous.luminance(x: x, y: y + shift))
                        count += 1
                    }
                }
                bandErrors.append(count == 0 ? 1 : error / Double(count))
            }
            let sorted = bandErrors.sorted()
            let trimmed = sorted.dropLast(max(0, sorted.count / 4))
            let error = trimmed.reduce(0, +) / Double(max(1, trimmed.count))
            let support = bandErrors.filter { $0 < max(0.075, error * 1.65) }.count
            let texture = textureVariance(allValues)
            guard error < 0.13 else { continue }
            result.append(Candidate(shift: shift, error: error, support: support, texture: texture))
        }
        let sorted = result.sorted {
            if abs($0.error - $1.error) > 0.0005 { return $0.error < $1.error }
            return $0.support > $1.support
        }
        // Coarse matching narrows the search; this full-resolution pass is
        // essential on Retina captures where the real displacement is not a
        // multiple of the coarse step.
        var refined = sorted
        for coarse in sorted.prefix(6) {
            for shift in max(1, coarse.shift - coarseStep)...min(maxShift, coarse.shift + coarseStep) {
                let candidate = candidateAt(
                    shift: shift,
                    previous: previous,
                    next: next,
                    stepX: 1,
                    stepY: 1,
                    bandCount: bandCount,
                    bandHeight: bandHeight
                )
                if candidate.error < 0.13 { refined.append(candidate) }
            }
        }
        var bestByShift: [Int: Candidate] = [:]
        for candidate in refined {
            if let existing = bestByShift[candidate.shift], existing.error <= candidate.error { continue }
            bestByShift[candidate.shift] = candidate
        }
        return bestByShift.values.sorted {
            if abs($0.error - $1.error) > 0.0005 { return $0.error < $1.error }
            return $0.support > $1.support
        }
    }

    private func candidateAt(
        shift: Int,
        previous: PixelBuffer,
        next: PixelBuffer,
        stepX: Int,
        stepY: Int,
        bandCount: Int,
        bandHeight: Int
    ) -> Candidate {
        let overlapHeight = previous.height - shift
        var bandErrors: [Double] = []
        var allValues: [Double] = []
        for band in 0..<bandCount {
            let ratio = Double(band + 1) / Double(bandCount + 1)
            let center = min(previous.height - bandHeight / 2 - 1, max(bandHeight / 2, Int(Double(overlapHeight) * ratio)))
            var error = 0.0
            var count = 0
            for y in stride(from: max(0, center - bandHeight / 2), to: min(overlapHeight, center + bandHeight / 2), by: stepY) {
                for x in stride(from: 0, to: previous.width, by: stepX) {
                    error += pixelError(previous, next, x: x, lhsY: y + shift, rhsY: y)
                    allValues.append(previous.luminance(x: x, y: y + shift))
                    count += 1
                }
            }
            bandErrors.append(count == 0 ? 1 : error / Double(count))
        }
        let sorted = bandErrors.sorted()
        let trimmed = sorted.dropLast(max(0, sorted.count / 4))
        let error = trimmed.reduce(0, +) / Double(max(1, trimmed.count))
        let support = bandErrors.filter { $0 < max(0.075, error * 1.65) }.count
        return Candidate(shift: shift, error: error, support: support, texture: textureVariance(allValues))
    }

    private func pixelError(_ lhs: PixelBuffer, _ rhs: PixelBuffer, x: Int, lhsY: Int, rhsY: Int) -> Double {
        let i = (lhsY * lhs.width + x) * 4
        let j = (rhsY * rhs.width + x) * 4
        return (abs(Double(lhs.bytes[i]) - Double(rhs.bytes[j]))
            + abs(Double(lhs.bytes[i + 1]) - Double(rhs.bytes[j + 1]))
            + abs(Double(lhs.bytes[i + 2]) - Double(rhs.bytes[j + 2]))) / (3 * 255)
    }

    private func textureVariance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }
}

fileprivate extension VerticalImageStitcher.PixelBuffer {
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Keep CGImage's native pixel-coordinate order. ScreenCaptureKit and
        // CGImage.cropping use the same bottom-left pixel origin, so flipping
        // here would turn a downward scroll into an apparent reverse scroll.
        self.init(width: width, height: height, bytes: bytes)
    }
}
