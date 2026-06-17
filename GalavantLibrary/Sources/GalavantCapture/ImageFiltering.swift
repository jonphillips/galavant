import Foundation

/// Image-URL hygiene, ported from V1's `WebScraping` filters: drop tracking
/// pixels, social-button sprites, app-store badges, data URIs, and the like, and
/// keep only plausible photo extensions. Pure string work — no fetching, no
/// decoding (that's the storage tier's job, ADR-0009).
enum ImageFiltering {
  /// Substrings that mark an image URL as chrome/junk rather than a place photo.
  static let irrelevantMarkers = [
    "facebook", "instagram", "twitter", "yelp", "menu", "loader", "data:image",
    "gstatic.com", "pixel.wp.com", "bat.bing.com", "maps.googleapis.com/maps",
    "android", "appstore", "app-store", "sprite", "icon", "logo", "avatar",
    "1x1", "spacer", "blank",
  ]

  /// Path extensions we accept (empty = extensionless CDN URLs, which are common
  /// and usually fine).
  static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", ""]

  static func isRelevant(_ url: URL) -> Bool {
    let lower = url.absoluteString.lowercased()
    if irrelevantMarkers.contains(where: lower.contains) { return false }
    return allowedExtensions.contains(url.pathExtension.lowercased())
  }
}
