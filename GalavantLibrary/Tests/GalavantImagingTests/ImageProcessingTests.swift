import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import GalavantImaging

@Suite struct ImageProcessingTests {
  @Test("Downscales an oversized image to the display budget, preserving aspect ratio")
  func downscalesOversized() throws {
    let data = try makeImageData(width: 4000, height: 2000)
    let processed = try #require(ImageProcessing.process(data, format: .jpeg))

    // Longest edge clamped to the display budget; never upscaled the short edge.
    #expect(processed.width == ImageProcessing.displayMaxPixel)
    #expect(processed.height == ImageProcessing.displayMaxPixel / 2)
  }

  @Test("Does not upscale an image already under the budget")
  func leavesSmallImageAlone() throws {
    let data = try makeImageData(width: 800, height: 600)
    let processed = try #require(ImageProcessing.process(data, format: .jpeg))

    #expect(processed.width == 800)
    #expect(processed.height == 600)
  }

  @Test("Display tier compresses under the byte target")
  func compressesUnderTarget() throws {
    let data = try makeImageData(width: 4000, height: 3000, noisy: true)
    let processed = try #require(ImageProcessing.process(data, format: .jpeg))

    #expect(processed.display.count <= ImageProcessing.displayTargetBytes)
    // The thumbnail is much smaller than the display tier.
    #expect(processed.thumbnail.count < processed.display.count)
    // Both outputs are themselves decodable images.
    #expect(CGImageSourceCreateWithData(processed.display as CFData, nil) != nil)
    #expect(CGImageSourceCreateWithData(processed.thumbnail as CFData, nil) != nil)
  }

  @Test("Thumbnail clamps to the thumbnail budget")
  func thumbnailIsSmall() throws {
    let data = try makeImageData(width: 4000, height: 4000)
    let processed = try #require(ImageProcessing.process(data, format: .jpeg))
    let thumbSource = try #require(CGImageSourceCreateWithData(processed.thumbnail as CFData, nil))
    let thumb = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))

    #expect(thumb.width <= ImageProcessing.thumbnailMaxPixel)
    #expect(thumb.height <= ImageProcessing.thumbnailMaxPixel)
  }

  @Test("Non-image bytes return nil rather than throwing")
  func rejectsGarbage() {
    #expect(ImageProcessing.process(Data("not an image".utf8)) == nil)
  }

  // MARK: - Fixture synthesis (no bundled binaries)

  /// Draw a solid (or noisy) RGB image and encode it to PNG bytes — a self-contained
  /// source the processor can decode, with no fixture files in the repo.
  private func makeImageData(width: Int, height: Int, noisy: Bool = false) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    if noisy {
      // A photo-like image: a smooth diagonal gradient with mild per-block variation
      // — detailed enough to exceed the byte target at high quality (exercising the
      // step-down loop) but compressible like a real photograph, unlike pure noise.
      var generator = SystemRandomNumberGenerator()
      for x in stride(from: 0, to: width, by: 8) {
        for y in stride(from: 0, to: height, by: 8) {
          let gx = Double(x) / Double(width)
          let gy = Double(y) / Double(height)
          let jitter = Double.random(in: -0.08...0.08, using: &generator)
          context.setFillColor(
            red: min(max(gx + jitter, 0), 1),
            green: min(max(gy + jitter, 0), 1),
            blue: min(max((gx + gy) / 2 + jitter, 0), 1),
            alpha: 1
          )
          context.fill(CGRect(x: x, y: y, width: 8, height: 8))
        }
      }
    } else {
      context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let image = try #require(context.makeImage())

    let buffer = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil
      )
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return buffer as Data
  }
}
