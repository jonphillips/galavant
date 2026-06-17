import Foundation

/// The mutable accumulator the extraction passes write into. Scalar facts go
/// through `votes` (most-corroborated wins); collections (`images`, `socialURLs`,
/// `openingHours`, `schemaTypes`) accumulate as ordered-unique lists. Resolving
/// produces the immutable `ParsedPage`.
struct ParseBuilder {
  var votes = AttributeVotes()
  private(set) var images: [URL] = []
  private(set) var socialURLs: [URL] = []
  private(set) var openingHours: [String] = []
  private(set) var schemaTypes: [String] = []

  let sourceURL: URL?

  init(sourceURL: URL?) {
    self.sourceURL = sourceURL
  }

  // MARK: Collection accumulators (order-preserving, de-duplicated)

  mutating func addImage(_ rawValue: String?) {
    guard let url = resolvedURL(rawValue), ImageFiltering.isRelevant(url) else { return }
    if !images.contains(url) { images.append(url) }
  }

  mutating func addSocial(_ rawValue: String?) {
    guard let url = resolvedURL(rawValue) else { return }
    if !socialURLs.contains(url) { socialURLs.append(url) }
  }

  mutating func addOpeningHours(_ rawValue: String?) {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty, !openingHours.contains(value)
    else { return }
    openingHours.append(value)
  }

  mutating func addSchemaType(_ rawValue: String?) {
    guard let value = Self.normalizedSchemaType(rawValue),
      !schemaTypes.contains(value)
    else { return }
    schemaTypes.append(value)
  }

  // MARK: Resolve

  func build(capturedAt: Date) -> ParsedPage {
    let coordinate: ParsedCoordinate? = {
      guard let lat = votes.winner(.latitude).flatMap(Double.init),
        let lon = votes.winner(.longitude).flatMap(Double.init)
      else { return nil }
      return ParsedCoordinate(latitude: lat, longitude: lon)
    }()

    let address = ParsedAddress(
      street: votes.winner(.street),
      locality: votes.winner(.locality),
      region: votes.winner(.region),
      postalCode: votes.winner(.postalCode),
      country: votes.winner(.country)
    )

    // The page's own advertised site. Whether it's worth a second enrichment hop
    // (i.e. differs from `sourceURL`) is the orchestrator's call — we just surface
    // it; both URLs are on `ParsedPage`.
    let website = votes.winner(.websiteURL).flatMap(URL.init(string:))

    return ParsedPage(
      sourceURL: sourceURL,
      title: resolvedTitle(),
      titleIsStructured: (votes.winnerPriority(.title) ?? AttributeVotes.chromePriority)
        > AttributeVotes.chromePriority,
      summary: votes.winner(.summary),
      phone: votes.winner(.phone),
      email: votes.winner(.email),
      websiteURL: website,
      coordinate: coordinate,
      address: address,
      imageURLs: images,
      socialURLs: socialURLs,
      schemaTypes: schemaTypes,
      openingHours: openingHours,
      capturedAt: capturedAt
    )
  }

  /// The winning title, with a marketing tagline trimmed when the title came from
  /// page chrome (og:/twitter:/`<title>`): "Forestis Dolomites | Boutique Wellness
  /// Hotel in Brixen" → "Forestis Dolomites". A structured (JSON-LD/microdata)
  /// `name` is trusted verbatim — only the noisy chrome layer gets cleaned.
  private func resolvedTitle() -> String? {
    guard let title = votes.winner(.title) else { return nil }
    guard votes.winnerPriority(.title) == AttributeVotes.chromePriority else { return title }
    return Self.trimmingTagline(title)
  }

  /// Drop a `| site/tagline` suffix. The pipe is the one separator that reliably
  /// means "primary | secondary" (page/brand first); dashes and colons are used
  /// both ways ("Home — Alouette" puts the brand last), so those are left to the
  /// structured-name priority instead.
  private static func trimmingTagline(_ title: String) -> String {
    guard let pipe = title.firstIndex(of: "|") else { return title }
    let head = title[..<pipe].trimmingCharacters(in: .whitespacesAndNewlines)
    return head.isEmpty ? title : head
  }

  // MARK: Helpers

  /// Trim, ignore blanks, and resolve against the source URL so a relative path
  /// (`/img/hero.jpg`) from a structured value (JSON-LD/meta content) becomes
  /// absolute. Already-absolute URLs are unaffected.
  private func resolvedURL(_ rawValue: String?) -> URL? {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return URL(string: value, relativeTo: sourceURL)?.absoluteURL
  }

  /// schema.org types may arrive fully qualified (`http://schema.org/Restaurant`)
  /// or bare (`Restaurant`); keep the trailing token.
  private static func normalizedSchemaType(_ rawValue: String?) -> String? {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init)
  }
}
