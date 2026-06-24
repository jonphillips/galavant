import Foundation

/// A recognized outbound link worth a second enrichment hop: a known guide's
/// *place-detail* page (ADR-0021).
public struct RecognizedGuideLink: Equatable, Sendable {
  public var url: URL
  /// The guide's name — also the `IdeaEvaluation.sourceName` its rating will be stamped
  /// with, so the enricher can match against a judgment the idea may already carry.
  public var guide: String

  public init(url: URL, guide: String) {
    self.url = url
    self.guide = guide
  }
}

/// Picks the links on a `ParsedPage` that point at a place-detail page on a known
/// travel guide — the links the enricher follows for a rating the shared page itself
/// didn't carry (ADR-0021). Pure and domain-free; shares the `GuideHosts` table with
/// `EvaluationRecognizers`, so "what counts as a guide" has one definition.
///
/// A link qualifies on **host** (a known guide) **and** **path shape** (a single
/// place's page, not the guide's home / section / listing index). The path test is what
/// keeps "follow it" safe: a bare host match would chase a city listing — a page with no
/// one place's rating to read, or worse, *another* place's.
public enum GuideLinkRecognizer {
  /// Minimum non-empty path-segment depth for a place-detail page. Guides namespace by
  /// locale → region/category → place, so a per-place page cannot sit shallower than
  /// locale(1) + region/category(2) + the place's own slug(3). Home pages are depth 0,
  /// locale/category indexes 1–2; depth 3 is the first level an individual place's page
  /// must reach. Not a tuned middle value — the floor the URL scheme forces.
  static let minDetailDepth = 3

  /// Final-segment words that mark a listing/section/index page rather than a place.
  /// Rejected up front so neither path branch follows an index that happens to be deep
  /// or hyphenated (`…/the-list`, `…/restaurants`).
  private static let sectionKeywords: Set<String> = [
    "restaurants", "hotels", "bars", "the-list", "list", "search", "destinations",
    "guide", "awards", "results",
  ]

  /// The guide-detail links on the page, in document order (the enricher follows the
  /// first; ADR-0021 §4 caps it at one).
  public static func recognize(in page: ParsedPage) -> [RecognizedGuideLink] {
    page.links.compactMap { url in
      guard let guide = GuideHosts.guide(forHost: url.host()), isPlaceDetail(url, on: guide)
      else { return nil }
      return RecognizedGuideLink(url: url, guide: guide.name)
    }
  }

  private static func isPlaceDetail(_ url: URL, on guide: GuideHosts.Guide) -> Bool {
    let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }.map { $0.lowercased() }
    guard let last = segments.last, !sectionKeywords.contains(last) else { return false }

    // Strong signal: a known detail-path marker (Michelin's `/restaurant/`, `/hotel/`)
    // with a slug *after* it — `/restaurant/es-senz`, not the bare `/restaurants` index.
    if let marker = segments.firstIndex(where: { guide.detailPathMarkers.contains($0) }),
      marker < segments.count - 1
    {
      return true
    }

    // Generic shape for a guide we know only by host: deep enough, with a final segment
    // that isn't a section/index keyword (guarded above). We deliberately do **not**
    // require a hyphenated slug — single-word place names (`disfrutar`, `noma`) are
    // common and a hyphen test silently dropped them. The cost is occasionally following
    // a deep geographic index on a marker-less guide; the hop is best-effort and one-shot,
    // and `IdeaEvaluation.record` de-dups whatever it yields (ADR-0019 §3).
    return segments.count >= minDetailDepth
  }
}
