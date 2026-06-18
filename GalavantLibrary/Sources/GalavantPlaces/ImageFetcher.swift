import Dependencies
import Foundation

/// Downloads raw image bytes for a scraped image URL — the injectable I/O boundary
/// for capture's image storage (the cousin of `PlaceMatcher`/`ImageFetcher`). Kept
/// behind a closure so `CaptureModel` stays testable with a fixture (no network),
/// and so the share extension's single-image fetch is the only thing that touches
/// the wire there (the full ranked gallery is the app's job — M4g).
public struct ImageFetcher: Sendable {
  var fetch: @Sendable (_ url: URL) async -> Data?

  public init(fetch: @escaping @Sendable (_ url: URL) async -> Data?) {
    self.fetch = fetch
  }

  /// The image bytes, or nil on any failure (best-effort — a missing image must
  /// never block a capture from saving).
  public func callAsFunction(_ url: URL) async -> Data? {
    await fetch(url)
  }
}

extension ImageFetcher: DependencyKey {
  /// A generous cap so one oversized hero image can't blow the share extension's
  /// ~120 MB budget before processing shrinks it.
  static let maxBytes = 12 * 1024 * 1024

  public static let liveValue = ImageFetcher { url in
    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
      !data.isEmpty,
      data.count <= maxBytes
    else { return nil }
    return data
  }

  /// No network in tests/previews.
  public static let testValue = ImageFetcher { _ in nil }
}

extension DependencyValues {
  public var imageFetcher: ImageFetcher {
    get { self[ImageFetcher.self] }
    set { self[ImageFetcher.self] = newValue }
  }
}
