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
  /// Per attribute, candidate values in first-seen order, each with a tally.
  private var tallies: [PageAttribute: [(value: String, count: Int)]] = [:]

  /// Record a candidate value for an attribute. Blank/whitespace values are
  /// ignored so empty tags don't out-vote real data.
  mutating func add(_ attribute: PageAttribute, _ rawValue: String?) {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }
    var candidates = tallies[attribute] ?? []
    if let index = candidates.firstIndex(where: { $0.value == value }) {
      candidates[index].count += 1
    } else {
      candidates.append((value, 1))
    }
    tallies[attribute] = candidates
  }

  /// The winning value for an attribute: highest tally, ties to the earliest seen.
  func winner(_ attribute: PageAttribute) -> String? {
    guard let candidates = tallies[attribute], !candidates.isEmpty else { return nil }
    var best = candidates[0]
    for candidate in candidates.dropFirst() where candidate.count > best.count {
      best = candidate
    }
    return best.value
  }
}
