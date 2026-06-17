import Foundation
import GalavantCapture

/// How a scraped page becomes an Apple Maps match — the pure decision + scoring
/// half (no MapKit, no network), ported and modernized from V1's
/// `PlaceSearchStrategy`. The live execution (running `MKLocalSearch`/`CLGeocoder`,
/// picking the winner) wires these in M4c behind the existing injected boundaries;
/// keeping the policy pure makes it testable without either.
public enum PlaceMatching {
  /// The ordered signal ladder for resolving a parsed page to a map location
  /// (scraping-enrichment.md "signal ladder"): use the strongest signal the page
  /// gave us first, and only fall back to fuzzier ones. Region bias is a *hint*,
  /// not a filter, and the executor auto-widens to worldwide on a low-confidence
  /// best score — the bias never hard-excludes a famous-but-distant place.
  public enum Step: Equatable, Sendable {
    /// Scraped coordinates are authoritative — verify with a nearby search, no
    /// geocoding needed.
    case coordinates(latitude: Double, longitude: Double)
    /// A scraped postal address — geocode it.
    case geocodeAddress(String)
    /// Text search over `query`, biased toward a candidate region when capturing
    /// inside a trip's lens (the executor supplies the region).
    case biasedTextSearch(query: String)
    /// Last resort: the same query, unconstrained worldwide.
    case worldwideTextSearch(query: String)
  }

  /// Build the ladder from whatever signals the page surfaced. Always ends with a
  /// worldwide text search as the floor (provided we have *any* query text).
  public static func ladder(for page: ParsedPage) -> [Step] {
    var steps: [Step] = []
    if let coordinate = page.coordinate {
      steps.append(.coordinates(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
    if !page.address.isEmpty {
      steps.append(.geocodeAddress(page.address.oneLine))
    }
    let query = searchQuery(for: page)
    if !query.isEmpty {
      steps.append(.biasedTextSearch(query: query))
      steps.append(.worldwideTextSearch(query: query))
    }
    return steps
  }

  /// The natural-language query for a text search: the place name plus its city /
  /// region (stopwords dropped), which disambiguates a bare name worldwide
  /// ("Noma" needs "Copenhagen").
  public static func searchQuery(for page: ParsedPage) -> String {
    queryTokens(
      name: page.title,
      locality: page.address.locality,
      region: page.address.region
    )
    .joined(separator: " ")
  }

  // MARK: Scoring (V1's common-substring overlap)

  /// Score a candidate against the scraped place by counting word overlap in the
  /// name *and* the street — agreement on both is a strong match. The executor
  /// sorts candidates by this and compares the top score to a confidence
  /// threshold before accepting (else it widens the search).
  public static func score(
    candidateName: String,
    candidateStreet: String,
    scrapedName: String,
    scrapedStreet: String
  ) -> Int {
    commonWordCount(candidateName, scrapedName)
      + commonWordCount(candidateStreet, scrapedStreet)
  }

  /// Count of whitespace-delimited words appearing in both strings (case- and
  /// punctuation-insensitive).
  public static func commonWordCount(_ lhs: String, _ rhs: String) -> Int {
    let rightWords = Set(words(in: rhs))
    return words(in: lhs).filter(rightWords.contains).count
  }

  // MARK: Tokenizing

  /// Significant lowercase tokens from a place's name + locality + region, with
  /// stopwords and the booking-aggregator noise ("opentable", "reservations")
  /// filtered — V1's `generateAutoQueryTokens`.
  static func queryTokens(name: String?, locality: String?, region: String?) -> [String] {
    let stopwords: Set<String> = [
      "and", "at", "the", "in", "on", "of", "home", "online", "undetermined",
      "reservations", "reservation", "opentable", "resy", "menu",
    ]
    var seen = Set<String>()
    return [name, locality, region]
      .compactMap { $0 }
      .flatMap { words(in: $0) }
      .filter { !stopwords.contains($0) }
      .filter { seen.insert($0).inserted }
  }

  /// Split on whitespace and punctuation (keeping apostrophes inside words),
  /// lowercased, blanks dropped. V1's `galavantSeparatorSet`.
  static func words(in string: String) -> [String] {
    var separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    separators.remove("'")
    separators.remove("\u{2019}")  // curly apostrophe
    return string
      .components(separatedBy: separators)
      .map { $0.lowercased() }
      .filter { !$0.isEmpty }
  }
}
