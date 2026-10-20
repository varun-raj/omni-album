import Foundation
import ImageIO

/// Downsampling ImageIO decode, honouring EXIF orientation, in the image's own colour space. Never upsizes
/// past the source. `hdr: true` asks for the HDR rendition (gain map / PQ / HLG) on macOS 15+ and falls
/// back to SDR when the image has none.
public func decodeImage(at url: URL, maxPixel: CGFloat, hdr: Bool = false) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    if hdr, #available(macOS 15, *) {
        var h = opts; h[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, h as CFDictionary) { return img }
    }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}
