import Dependencies
import Foundation

/// A stock photo surfaced by an Unsplash search (ADR-0032). Domain-light and flat:
/// the CDN reference we hotlink (`thumbURL`/`regularURL`), a placeholder `color`,
/// and the attribution fields the Unsplash ToS requires the UI to display. Never
/// image bytes — a trip header is a reference, not a stored BLOB (unlike ADR-0009's
/// `ImageAsset`). `downloadLocation` is the endpoint the picker must ping when a
/// photo is *selected for use* (`registerDownload`) — also a ToS obligation.
public struct UnsplashPhoto: Equatable, Sendable, Identifiable {
  public var id: String
  /// `urls.thumb` — the grid cell in the picker.
  public var thumbURL: String
  /// `urls.regular` — what the trip header renders (persisted to `Trip`).
  public var regularURL: String
  /// `color` (hex) — the placeholder shown while the CDN image loads.
  public var color: String?
  public var photographerName: String
  public var photographerUsername: String
  /// `links.download_location` — pinged on selection (ToS). Not the image URL.
  public var downloadLocation: String

  public init(
    id: String,
    thumbURL: String,
    regularURL: String,
    color: String? = nil,
    photographerName: String,
    photographerUsername: String,
    downloadLocation: String
  ) {
    self.id = id
    self.thumbURL = thumbURL
    self.regularURL = regularURL
    self.color = color
    self.photographerName = photographerName
    self.photographerUsername = photographerUsername
    self.downloadLocation = downloadLocation
  }
}

/// The injectable Unsplash boundary (ADR-0032), same shape as `PlaceDiscoveryClient`
/// / `ImageFetcher` ([[inject-io-boundaries-early]]). Two verbs:
///
/// - `search(query:perPage:)` — `GET /search/photos`, `Client-ID` auth, defensive
///   decode (a malformed reply degrades to `[]`, like `PlaceDiscoveryClient.parse`).
/// - `registerDownload(_:)` — fire-and-forget ping of a photo's `download_location`
///   when it's selected for use. **A ToS obligation, not optional** — Unsplash
///   requires a tracked-download call on use; skipping it risks the access key.
///
/// The live value reads the public `Client-ID` from `\.unsplashAccessKey` (build
/// config, not hardcoded — §3). `testValue.search` returns `[]` and
/// `registerDownload` is a no-op, so the picker's parse/seed logic tests with no wire.
///
/// Domain-free stock-photo search — a jon-platform lift candidate (like
/// WebExtractorKit) *if* a second app wants it; injected here for now.
public struct UnsplashClient: Sendable {
  var search: @Sendable (_ query: String, _ perPage: Int) async throws -> [UnsplashPhoto]
  var registerDownload: @Sendable (_ downloadLocation: String) async -> Void

  public init(
    search: @escaping @Sendable (_ query: String, _ perPage: Int) async throws -> [UnsplashPhoto],
    registerDownload: @escaping @Sendable (_ downloadLocation: String) async -> Void
  ) {
    self.search = search
    self.registerDownload = registerDownload
  }

  /// Photos matching `query`, most-relevant first. Throws on transport/auth failure
  /// so a bad key surfaces; a malformed body degrades to `[]`.
  public func callAsFunction(query: String, perPage: Int = 20) async throws -> [UnsplashPhoto] {
    try await search(query, perPage)
  }

  /// Ping a selected photo's tracked-download endpoint (ToS). Best-effort — never
  /// throws, never blocks the write that follows it.
  public func registerDownload(for photo: UnsplashPhoto) async {
    await registerDownload(photo.downloadLocation)
  }
}

extension UnsplashClient: DependencyKey {
  static let apiBase = URL(string: "https://api.unsplash.com")!

  public static let liveValue = UnsplashClient(
    search: { query, perPage in
      @Dependency(\.unsplashAccessKey) var accessKey
      var comps = URLComponents(
        url: apiBase.appending(path: "search/photos"), resolvingAgainstBaseURL: false
      )!
      comps.queryItems = [
        URLQueryItem(name: "query", value: query),
        URLQueryItem(name: "per_page", value: String(perPage)),
        URLQueryItem(name: "content_filter", value: "high"),
      ]
      var request = URLRequest(url: comps.url!)
      request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")
      request.setValue("v1", forHTTPHeaderField: "Accept-Version")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
      else { throw UnsplashError.badResponse }
      return parse(data)
    },
    registerDownload: { location in
      guard let url = URL(string: location) else { return }
      @Dependency(\.unsplashAccessKey) var accessKey
      var request = URLRequest(url: url)
      request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")
      request.setValue("v1", forHTTPHeaderField: "Accept-Version")
      _ = try? await URLSession.shared.data(for: request)
    }
  )

  /// No network in tests/previews — the parse and the picker are exercised with an
  /// injected stub.
  public static let testValue = UnsplashClient(
    search: { _, _ in [] },
    registerDownload: { _ in }
  )

  /// Decode the `results` array defensively — a non-conforming element (missing id
  /// or URLs) is dropped rather than failing the whole search, like
  /// `PlaceDiscoveryClient.parse`.
  static func parse(_ data: Data) -> [UnsplashPhoto] {
    guard let root = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
    return root.results.compactMap { result in
      guard
        let id = result.id,
        let thumb = result.urls?.thumb,
        let regular = result.urls?.regular,
        let downloadLocation = result.links?.download_location
      else { return nil }
      return UnsplashPhoto(
        id: id,
        thumbURL: thumb,
        regularURL: regular,
        color: result.color,
        photographerName: result.user?.name ?? "",
        photographerUsername: result.user?.username ?? "",
        downloadLocation: downloadLocation
      )
    }
  }

  // Wire shapes — all optional so a partial element degrades rather than throwing.
  private struct SearchResponse: Decodable { var results: [Result] = [] }
  private struct Result: Decodable {
    var id: String?
    var color: String?
    var urls: URLs?
    var links: Links?
    var user: User?
  }
  private struct URLs: Decodable {
    var regular: String?
    var thumb: String?
  }
  private struct Links: Decodable { var download_location: String? }
  private struct User: Decodable {
    var name: String?
    var username: String?
  }
}

public enum UnsplashError: Error {
  case badResponse
}

extension DependencyValues {
  public var unsplashClient: UnsplashClient {
    get { self[UnsplashClient.self] }
    set { self[UnsplashClient.self] = newValue }
  }
}

/// The Unsplash **Access Key** — a *public* Client-ID designed to ship client-side
/// (ADR-0032 §3), so unlike the frontier BYO-key path (ADR-0014) it isn't a Keychain
/// secret and isn't entered per-user. But it stays out of package source: the live
/// value reads it from the app's Info.plist (`UNSPLASH_ACCESS_KEY`, fed by an
/// xcconfig build setting). Empty when unconfigured — searches then fail with
/// `badResponse`, which the picker surfaces as an empty state rather than crashing.
private enum UnsplashAccessKeyDependency: DependencyKey {
  static let liveValue =
    (Bundle.main.object(forInfoDictionaryKey: "UNSPLASH_ACCESS_KEY") as? String) ?? ""
  static let testValue = "test-access-key"
}

extension DependencyValues {
  public var unsplashAccessKey: String {
    get { self[UnsplashAccessKeyDependency.self] }
    set { self[UnsplashAccessKeyDependency.self] = newValue }
  }
}
