import Foundation
import CoreGraphics

@main
struct ScrollStitcherHarness {
    static func main() {
        let width = 96
        let frameHeight = 64
        let sourceHeight = 256
        let source = fixture(width: width, height: sourceHeight, offset: 0)
        var stitcher = VerticalImageStitcher()
        check(stitcher.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight)) == .firstFrame(width: width, height: frameHeight), "first frame")
        var accepted = 0
        for offset in [17, 41, 68, 103, 135, 168, 192] {
            let result = stitcher.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: offset, height: frameHeight))
            if case .accepted = result { accepted += 1 } else { check(false, "accepted offset \(offset): \(result)") }
        }
        check(accepted == 7, "uneven frames accepted")
        check(stitcher.progress?.height == 256, "height reconstructed")
        let output = checkImage(stitcher.makeImage(), width: width, height: 256)
        check(output == source, "final pixels equal source")

        var cgStitcher = VerticalImageStitcher()
        _ = cgStitcher.append(cgImage(topLeft: slice(source, width: width, y: 0, height: frameHeight), width: width, height: frameHeight))
        _ = cgStitcher.append(cgImage(topLeft: slice(source, width: width, y: 17, height: frameHeight), width: width, height: frameHeight))
        check(checkImage(cgStitcher.makeImage(), width: width, height: 81) == Array(source[0..<(width * 81 * 4)]), "CGImage coordinate orientation")
        let fullSourceImage = cgImage(topLeft: source, width: width, height: sourceHeight)
        var croppedStitcher = VerticalImageStitcher()
        _ = croppedStitcher.append(fullSourceImage.cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight))!)
        _ = croppedStitcher.append(fullSourceImage.cropping(to: CGRect(x: 0, y: 17, width: width, height: frameHeight))!)
        check(croppedStitcher.progress?.height == 81, "CGImage crop geometry")
        check(checkImage(croppedStitcher.makeImage(), width: width, height: 81) == Array(source[0..<(width * 81 * 4)]), "CGImage crop pixels")

        var undo = VerticalImageStitcher()
        _ = undo.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight))
        _ = undo.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 17, height: frameHeight))
        _ = undo.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 41, height: frameHeight))
        check(undo.undoLast(), "undo last strip")
        check(undo.progress?.height == 81, "undo restores previous height")
        check(undo.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 41, height: frameHeight)) != .dimensionsChanged, "resume after undo")

        var duplicate = VerticalImageStitcher()
        _ = duplicate.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight))
        check(duplicate.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight)) == .duplicate, "duplicate rejected")
        let before = duplicate.progress
        let unrelated = [UInt8](repeating: 127, count: width * frameHeight * 4)
        check(duplicate.appendRGBA(width: width, height: frameHeight, bytes: unrelated) != .accepted(addedHeight: 0, totalHeight: 0, segmentCount: 0), "bad frame does not fabricate success")
        check(duplicate.progress == before, "bad frame leaves result unchanged")
        check(duplicate.undoLast() == false, "undo first frame disabled")

        var reverse = VerticalImageStitcher()
        _ = reverse.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight))
        _ = reverse.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 17, height: frameHeight))
        check(reverse.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight)) == .reverse, "reverse rejected")
        check(reverse.progress?.height == 81, "reverse leaves result unchanged")

        var nonOverlap = VerticalImageStitcher()
        _ = nonOverlap.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight))
        check(nonOverlap.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 60, height: frameHeight)) != .accepted(addedHeight: 60, totalHeight: 124, segmentCount: 1), "non-overlap rejected")
        check(nonOverlap.progress?.height == frameHeight, "non-overlap leaves result unchanged")

        var repeated = VerticalImageStitcher()
        let repeatedSource = fixture(width: width, height: 128, offset: 0, period: 8)
        _ = repeated.appendRGBA(width: width, height: frameHeight, bytes: slice(repeatedSource, width: width, y: 0, height: frameHeight))
        let repeatedResult = repeated.appendRGBA(width: width, height: frameHeight, bytes: slice(repeatedSource, width: width, y: 24, height: frameHeight))
        check(repeatedResult == .duplicate || repeatedResult == .ambiguous || repeatedResult == .lowTexture || repeatedResult == .insufficientOverlap, "repeated rows rejected")
        check(repeated.progress?.height == frameHeight, "repeated rows leave result unchanged")

        for scale in [1, 2] {
            let scaledWidth = width * scale
            let scaledFrameHeight = frameHeight * scale
            let scaledSource = fixture(width: scaledWidth, height: 256 * scale, offset: 0)
            var scaled = VerticalImageStitcher()
            _ = scaled.appendRGBA(width: scaledWidth, height: scaledFrameHeight, bytes: slice(scaledSource, width: scaledWidth, y: 0, height: scaledFrameHeight))
            _ = scaled.appendRGBA(width: scaledWidth, height: scaledFrameHeight, bytes: slice(scaledSource, width: scaledWidth, y: 17 * scale, height: scaledFrameHeight))
            check(scaled.progress?.height == 81 * scale, "scale \(scale)x geometry")
            check(checkImage(scaled.makeImage(), width: scaledWidth, height: 81 * scale) == Array(scaledSource[0..<(scaledWidth * 81 * scale * 4)]), "scale \(scale)x pixels")
        }

        // Retina-sized height exercises coarseStep > 1 and a displacement
        // that is deliberately not divisible by that coarse search step.
        let tallWidth = 96, tallFrameHeight = 600
        let tallSource = fixture(width: tallWidth, height: 1_200, offset: 0)
        var tall = VerticalImageStitcher()
        _ = tall.appendRGBA(width: tallWidth, height: tallFrameHeight, bytes: slice(tallSource, width: tallWidth, y: 0, height: tallFrameHeight))
        let tallFirstResult = tall.appendRGBA(width: tallWidth, height: tallFrameHeight, bytes: slice(tallSource, width: tallWidth, y: 238, height: tallFrameHeight))
        check({ if case .accepted = tallFirstResult { return true }; return false }(), "tall first non-coarse displacement")
        check({ if case .accepted = tall.appendRGBA(width: tallWidth, height: tallFrameHeight, bytes: slice(tallSource, width: tallWidth, y: 473, height: tallFrameHeight)) { return true }; return false }(), "tall second non-coarse displacement")
        check(tall.progress?.height == 1_073, "tall geometry")
        check(checkImage(tall.makeImage(), width: tallWidth, height: 1_073) == Array(tallSource[0..<(tallWidth * 1_073 * 4)]), "tall pixels")

        var tallReverse = VerticalImageStitcher()
        _ = tallReverse.appendRGBA(width: tallWidth, height: tallFrameHeight, bytes: slice(tallSource, width: tallWidth, y: 0, height: tallFrameHeight))
        _ = tallReverse.appendRGBA(width: tallWidth, height: tallFrameHeight, bytes: slice(tallSource, width: tallWidth, y: 238, height: tallFrameHeight))
        check(tallReverse.appendRGBA(width: tallWidth, height: tallFrameHeight, bytes: slice(tallSource, width: tallWidth, y: 0, height: tallFrameHeight)) == .reverse, "tall reverse displacement")

        var limitedConfig = VerticalImageStitcher.Configuration()
        limitedConfig.maximumHeight = frameHeight
        var limited = VerticalImageStitcher(configuration: limitedConfig)
        _ = limited.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight))
        check(limited.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 17, height: frameHeight)) == .tooLarge, "height limit")
        check(limited.progress?.height == frameHeight, "limit preserves result")

        var memoryConfig = VerticalImageStitcher.Configuration()
        memoryConfig.memoryBudgetBytes = 130_000
        var memoryLimited = VerticalImageStitcher(configuration: memoryConfig)
        _ = memoryLimited.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 0, height: frameHeight))
        let acceptedBeforeBudget = memoryLimited.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 17, height: frameHeight))
        check({ if case .accepted = acceptedBeforeBudget { return true }; return false }(), "small budget accepts first strip")
        let preserved = memoryLimited.progress
        let budgetResult = memoryLimited.appendRGBA(width: width, height: frameHeight, bytes: slice(source, width: width, y: 41, height: frameHeight))
        check(budgetResult == .tooLarge, "small budget stops before over-allocation")
        check(memoryLimited.progress == preserved && memoryLimited.makeImage() != nil, "small budget preserves renderable result")
        print("scroll stitcher harness passed: \(stitcher.progress?.width ?? 0)x\(stitcher.progress?.height ?? 0), segments=\(stitcher.segmentCount)")
    }

    private static func fixture(width: Int, height: Int, offset: Int, period: Int = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let effectiveY = period > 0 ? (y + offset) % period : y + offset
                let value = UInt8((x * 17 + effectiveY * 29 + effectiveY * effectiveY * 13 + ((x / 7 + effectiveY / 5) % 2) * 61) & 0xff)
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value ^ 0x35; bytes[i + 2] = value ^ 0x7a; bytes[i + 3] = 255
            }
        }
        return bytes
    }

    private static func slice(_ source: [UInt8], width: Int, y: Int, height: Int) -> [UInt8] {
        Array(source[(y * width * 4)..<((y + height) * width * 4)])
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    private static func checkImage(_ image: CGImage?, width: Int, height: Int) -> [UInt8] {
        guard let image else { fputs("FAIL: final image missing\n", stderr); exit(1) }
        check(image.width == width && image.height == height, "final image dimensions")
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return raw
    }

    private static func cgImage(topLeft: [UInt8], width: Int, height: Int) -> CGImage {
        var raw = topLeft
        let rowBytes = width * 4
        let context = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
