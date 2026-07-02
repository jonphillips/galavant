import Dependencies
import Foundation
import LLMClientKit

/// A place the discovery pass surfaced (ADR-0018, M6e slice 0). Domain-light and
/// flat — the model finds and structures, the app owns resolution/dedup/persistence
/// downstream (slices 1–2). `kind` is the model's free-text guess; mapping it to an
/// `IdeaKind` and resolving a coordinate is the resolution slice's job, not this one.
public struct DiscoveredCandidate: Equatable, Sendable, Identifiable {
  public var name: String
  public var kind: String?
  public var locality: String?
  public var region: String?
  public var note: String?
  public var sourceURL: String?

  public var id: String { (sourceURL ?? "") + "|" + name }

  public init(
    name: String, kind: String? = nil, locality: String? = nil,
    region: String? = nil, note: String? = nil, sourceURL: String? = nil
  ) {
    self.name = name
    self.kind = kind
    self.locality = locality
    self.region = region
    self.note = note
    self.sourceURL = sourceURL
  }
}

/// Web-search-grounded discovery (ADR-0018): query + region → a set of candidate
/// places, via **one** frontier `ModelClient.complete` call with Anthropic's
/// server-side `web_search` tool enabled. The model finds and structures into a
/// strict JSON array; this client parses it. The model never writes — the app owns
/// dedup/persistence (slices 1–2). Frontier-only/BYO-key: on-device can't web-search
/// (ADR-0014), so the live path uses `.frontier(.anthropic)`.
///
/// Injectable like the rest of the package (`inject-io-boundaries-early`): the live
/// value calls the model, `testValue` returns `[]` so the parser/ladder is the tested
/// default with no network.
public struct PlaceDiscoveryClient: Sendable {
  var discover: @Sendable (_ query: String, _ region: String) async throws -> [DiscoveredCandidate]

  public init(
    discover: @escaping @Sendable (_ query: String, _ region: String) async throws
      -> [DiscoveredCandidate]
  ) {
    self.discover = discover
  }

  /// Candidates for `query` scoped to `region` (a free-text area like "the Loire").
  /// Throws on transport/auth failure so the spike surfaces it; a malformed model
  /// reply degrades to `[]`.
  public func callAsFunction(query: String, region: String) async throws -> [DiscoveredCandidate] {
    try await discover(query, region)
  }
}

extension PlaceDiscoveryClient: DependencyKey {
  public static let liveValue = PlaceDiscoveryClient { query, region in
    @Dependency(\.modelClient) var modelClient
    let request = ModelRequest(
      tier: .frontier(.anthropic),
      system: Self.instructions,
      prompt: Self.prompt(query: query, region: region),
      maxTokens: 4096,
      webSearchMaxUses: 8
    )
    let response = try await modelClient.complete(request)
    return Self.parse(response.text)
  }

  /// No network in tests/previews — the parse and the spike UI are exercised with an
  /// injected stub.
  public static let testValue = PlaceDiscoveryClient { _, _ in [] }

  static let instructions = """
    You research places that match a request, grounded in web search. Find real, \
    currently-operating places — search the web; do not rely on memory. Prefer \
    authoritative sources. Do not invent places, addresses, or details; omit a field \
    you cannot verify rather than guessing.

    Respond with ONLY a JSON array (no prose). Each element: "name" (required), and \
    optionally "kind" (a short category like restaurant / museum / hotel / bar), \
    "locality" (city or town), "region" (wider area), "note" (one neutral sentence, \
    no marketing), "sourceURL" (where you found it). Return [] if you find nothing.
    """

  static func prompt(query: String, region: String) -> String {
    """
    Request: \(query)
    Region: \(region)

    Find the places that match, within that region, as a JSON array.
    """
  }

  /// Parse the model's JSON array defensively — a non-array, a missing name, or a
  /// malformed element drops that element rather than failing the whole pass.
  static func parse(_ text: String) -> [DiscoveredCandidate] {
    guard let data = jsonArraySlice(text)?.data(using: .utf8),
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return array.compactMap { element in
      guard let name = (element["name"] as? String)?.cleaned else { return nil }
      return DiscoveredCandidate(
        name: name,
        kind: (element["kind"] as? String)?.cleaned,
        locality: (element["locality"] as? String)?.cleaned,
        region: (element["region"] as? String)?.cleaned,
        note: (element["note"] as? String)?.cleaned,
        sourceURL: (element["sourceURL"] as? String)?.cleaned
      )
    }
  }

  /// Slice out the outermost `[ … ]` so a chatty model that wraps the array in prose
  /// still parses. `nil` when no array is present.
  private static func jsonArraySlice(_ text: String) -> String? {
    guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close
    else { return nil }
    return String(text[open...close])
  }
}

extension DependencyValues {
  public var placeDiscoveryClient: PlaceDiscoveryClient {
    get { self[PlaceDiscoveryClient.self] }
    set { self[PlaceDiscoveryClient.self] = newValue }
  }
}

extension String {
  fileprivate var cleaned: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
