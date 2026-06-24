import Foundation

/// The mutable accumulator the extraction passes write into. Scalar facts go
/// through `votes` (most-corroborated wins); collections (`images`, `socialURLs`,
/// `openingHours`, `schemaTypes`) accumulate as ordered-unique lists. Resolving
/// produces the immutable `ParsedPage`.
struct ParseBuilder {
  var votes = AttributeVotes()
  private(set) var images: [URL] = []
  private(set) var socialURLs: [URL] = []
  private(set) var links: [URL] = []
  private(set) var openingHours: [String] = []
  private(set) var schemaTypes: [String] = []
  private(set) var evaluations: [ParsedEvaluation] = []

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

  /// Record an outbound anchor href. Keeps only absolute `http(s)` links (drops
  /// `mailto:`/`tel:`/`javascript:`), strips the `#fragment` (so `/x` and `/x#section`
  /// collapse to one entry and a same-page jump is dropped), and skips a self-link back
  /// to `sourceURL` — leaving the raw set of *other* pages this one points at.
  mutating func addLink(_ rawValue: String?) {
    guard let resolved = resolvedURL(rawValue),
      let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return }
    var stripped = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
    stripped?.fragment = nil
    guard let url = stripped?.url?.absoluteURL,
      !isSelfLink(url),
      !links.contains(url)
    else { return }
    links.append(url)
  }

  /// Whether `url` is the page's own URL, ignoring a trailing-slash difference so a
  /// `https://site.com` home link doesn't slip past the self-link filter when the page
  /// was fetched as `https://site.com/` (or vice versa).
  private func isSelfLink(_ url: URL) -> Bool {
    guard let sourceURL else { return false }
    func key(_ u: URL) -> String {
      var s = u.absoluteString
      while s.hasSuffix("/") { s.removeLast() }
      return s
    }
    return key(url) == key(sourceURL)
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

  /// Record a detected source judgment, de-duplicated on (source, kind, value) so a
  /// rating echoed across JSON-LD and a host pattern is kept once. Deterministic
  /// recognizers run first, so a later duplicate is dropped, not the earlier vote.
  mutating func addEvaluation(_ evaluation: ParsedEvaluation) {
    let isDuplicate = evaluations.contains {
      $0.sourceName.caseInsensitiveCompare(evaluation.sourceName) == .orderedSame
        && $0.kind == evaluation.kind
        && $0.valueText.caseInsensitiveCompare(evaluation.valueText) == .orderedSame
    }
    guard !isDuplicate else { return }
    evaluations.append(evaluation)
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
      links: links,
      schemaTypes: schemaTypes,
      openingHours: openingHours,
      capturedAt: capturedAt,
      evaluations: evaluations
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
