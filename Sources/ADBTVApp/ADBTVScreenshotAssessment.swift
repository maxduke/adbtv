import ADBClientCore
import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

enum ADBTVScreenshotValidationError: Error, Equatable {
    case undecodableImage
    case tooManyPixels
}

enum ADBTVScreenshotAssessment: Equatable, Sendable {
    case content
    case appearsBlank

#if canImport(ImageIO)
    static func assess(_ screenshot: ADBTVScreenshot) throws -> Self {
        // Accommodates 8K screenshots without accepting a tiny compressed 1 GB bitmap.
        guard screenshot.width * screenshot.height <= 40_000_000 else {
            throw ADBTVScreenshotValidationError.tooManyPixels
        }
        guard let source = CGImageSourceCreateWithData(screenshot.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width == screenshot.width, image.height == screenshot.height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ADBTVScreenshotValidationError.undecodableImage
        }
        try Task.checkCancellation()
        // Inspect only a small sample. This is an advisory, not DRM detection.
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drewImage = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
            return true
        }
        guard drewImage else { throw ADBTVScreenshotValidationError.undecodableImage }
        return assessRGBA(pixels)
    }
#endif

    static func assessRGBA(_ pixels: [UInt8]) -> Self {
        guard !pixels.isEmpty, pixels.count.isMultiple(of: 4) else { return .content }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[offset + 3] > 0,
               (pixels[offset] > 8 || pixels[offset + 1] > 8 || pixels[offset + 2] > 8) {
                return .content
            }
        }
        return .appearsBlank
    }
}
