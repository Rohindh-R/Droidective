import AppKit
import CoreImage
import CoreVideo
import Foundation

/// Converts a decoded frame's pixel buffer into shareable image formats for the
/// in-mirror screenshot.
enum MirrorImage {
    static func cgImage(from imageBuffer: CVImageBuffer) -> CGImage? {
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    static func pngData(from imageBuffer: CVImageBuffer) -> Data? {
        guard let cgImage = cgImage(from: imageBuffer) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    static func nsImage(from imageBuffer: CVImageBuffer) -> NSImage? {
        guard let cgImage = cgImage(from: imageBuffer) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
