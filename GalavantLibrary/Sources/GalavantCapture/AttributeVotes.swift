import Foundation

/// The scalar attributes resolved by **value voting** — single-valued facts where
/// several extraction layers may disagree and the most-corroborated answer should
/// win. (Collections — images, social links, opening hours, schema types — are
/// accumulated separately as ordered-unique lists, not voted.)
enum PageAttribute: Hashable, CaseIterable {
  case title
  case summary
  case phone
  case email
  case websiteURL
  case latitude
  case longitude
  case street
  case locality
  case region
  case postalCode
  case country
}

/// Value voting, ported from the V1 server's `consolidate_scored_attrs`: every
/// extraction pass *adds a candidate* for an attribute rather than overwriting, and
/// the most-seen value wins. Agreement between JSON-LD, OpenGraph, and microdata
/// is itself the confidence signal — cheap and surprisingly effective.
///
/// Ties break toward the **earliest** candidate seen, so running the more
/// authoritative passes first (JSON-LD before microdata) makes them win ties.
struct AttributeVotes {
  /// Source authority, highest wins regardless of tally. JSON-LD is the cleanest,
  /// most curated schema.org source; microdata is structured but often scattered or
  /// derived from page chrome (e.g. Squarespace emits `<meta itemprop="name">` set
  /// to the section title "Home — Alouette"); page chrome (`og:`/`twitter:`/
  /// `<title>`) is the noisiest and gets echoed across several tags. So a JSON-LD
  /// `name` must outrank a microdata `name` that merely echoes the page title, and
  /// both outrank bare chrome — even when the chrome out-counts them.
  static let chromePriority = 0
  static let microdataPriority = 1
  static let jsonLDPriority = 2

  /// Per attribute, candidate values in first-seen order, each with a tally and the
  /// highest source priority that voted for it.
  private var tallies: [PageAttribute: [(value: String, count: Int, priority: Int)]] = [:]

  /// Record a candidate value for an attribute. Blank/whitespace values are
  /// ignored so empty tags don't out-vote real data.
  mutating func add(_ attribute: PageAttribute, _ rawValue: String?, priority: Int = chromePriority) {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }
    var candidates = tallies[attribute] ?? []
    if let index = candidates.firstIndex(where: { $0.value == value }) {
      candidates[index].count += 1
      candidates[index].priority = max(candidates[index].priority, priority)
    } else {
      candidates.append((value, 1, priority))
    }
    tallies[attribute] = candidates
  }

  /// The winning value for an attribute: highest priority, then highest tally, then
  /// (via the strict comparison over first-seen order) the earliest candidate.
  func winner(_ attribute: PageAttribute) -> String? {
    best(of: attribute)?.value
  }

  /// The source priority that carried the winning value (nil if none) — lets the
  /// builder treat a chrome-tier title more skeptically than a structured one.
  func winnerPriority(_ attribute: PageAttribute) -> Int? {
    best(of: attribute)?.priority
  }

  private func best(of attribute: PageAttribute) -> (value: String, count: Int, priority: Int)? {
    guard let candidates = tallies[attribute], !candidates.isEmpty else { return nil }
    var best = candidates[0]
    for candidate in candidates.dropFirst()
    where (candidate.priority, candidate.count) > (best.priority, best.count) {
      best = candidate
    }
    return best
  }
}
