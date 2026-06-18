import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The result of processing one source image: the display-tier bytes the UI
/// renders and a small thumbnail for lists/map pins (ADR-0009 §4). Both are the
/// *compressed* bytes — the canonical, syncable form; the decoded bitmap is a
/// device-local cache the caller re-derives on demand (§5).
public struct ProcessedImage: Equatable, Sendable {
  /// Display-tier bytes: resized to `displayMaxPixel` longest edge, compressed
  /// toward `displayTargetBytes` (comfortably under CloudKit's ~1 MB field cap).
  public var display: Data
  /// Thumbnail bytes: resized to `thumbnailMaxPixel` longest edge.
  public var thumbnail: Data
  /// The display image's pixel dimensions after resizing (orientation applied).
  public var width: Int
  public var height: Int

  public init(display: Data, thumbnail: Data, width: Int, height: Int) {
    self.display = display
    self.thumbnail = thumbnail
    self.width = width
    self.height = height
  }
}

/// Pure resize/compress/thumbnail over image bytes (ADR-0009 §2). Imports only
/// Foundation/CoreGraphics/ImageIO — no persistence, no UI — so it is unit-testable
/// with raw bytes and is the portable extraction candidate. Never upscales: a
/// source smaller than the target edge passes through at its own size.
public enum ImageProcessing {
  /// Output container. HEIC is the default (better ratio at travel-photo sizes);
  /// JPEG is the universal fallback.
  public enum Format: Sendable {
    case heic
    case jpeg

    var utType: CFString {
      switch self {
      case .heic: UTType.heic.identifier as CFString
      case .jpeg: UTType.jpeg.identifier as CFString
      }
    }
  }

  /// Longest-edge pixel budget for the display tier (~1600 px, ADR-0009 §4).
  public static let displayMaxPixel = 1600
  /// Longest-edge pixel budget for the thumbnail.
  public static let thumbnailMaxPixel = 320
  /// Soft byte target for the display tier (≈300 KB, ADR-0009 §4) — quality steps
  /// down until the output is under it or the floor is reached.
  public static let displayTargetBytes = 300 * 1024

  /// Process source bytes into display + thumbnail tiers, or `nil` when the bytes
  /// aren't a decodable image. Best-effort and pure; safe to call off the main actor.
  public static func process(
    _ data: Data,
    format: Format = .heic,
    displayMaxPixel: Int = displayMaxPixel,
    thumbnailMaxPixel: Int = thumbnailMaxPixel,
    displayTargetBytes: Int = displayTargetBytes
  ) -> ProcessedImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    guard
      let display = downscaled(source, maxPixel: displayMaxPixel),
      let thumbnail = downscaled(source, maxPixel: thumbnailMaxPixel),
      let displayData = encode(display, format: format, targetBytes: displayTargetBytes),
      let thumbnailData = encode(thumbnail, format: format, targetBytes: nil)
    else { return nil }
    return ProcessedImage(
      display: displayData,
      thumbnail: thumbnailData,
      width: display.width,
      height: display.height
    )
  }

  /// Downscale via ImageIO's thumbnail path — decodes straight to the target size
  /// (cheap, no full-size intermediate) and bakes in EXIF orientation. Won't upscale.
  private static func downscaled(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Encode a CGImage, stepping quality down toward `targetBytes` when given one.
  private static func encode(_ image: CGImage, format: Format, targetBytes: Int?) -> Data? {
    func attempt(_ quality: Double) -> Data? {
      let buffer = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          buffer as CFMutableData, format.utType, 1, nil
        )
      else { return nil }
      CGImageDestinationAddImage(
        destination, image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
      )
      guard CGImageDestinationFinalize(destination) else { return nil }
      return buffer as Data
    }

    guard let targetBytes else { return attempt(0.7) }
    var quality = 0.8
    var data = attempt(quality)
    while let current = data, current.count > targetBytes, quality > 0.4 {
      quality -= 0.15
      data = attempt(quality)
    }
    return data
  }
}
