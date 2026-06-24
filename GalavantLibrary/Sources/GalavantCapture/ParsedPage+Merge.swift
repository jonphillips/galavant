import Foundation

extension ParsedPage {
  /// Merge another parsed page into this one, **fill-blanks-only** — the same
  /// confirm-and-tweak rule capture uses against Apple Maps, applied page↔page
  /// (ADR-0021 §3). Scalar facts the other page carries fill only the fields this page
  /// left blank; ordered collections append the other's new entries; evaluations append
  /// through the same (source, kind, value) de-dup `ParseBuilder` uses, so a rating both
  /// pages assert is kept once. `sourceURL`, `capturedAt`, and `titleIsStructured`
  /// remain this page's — the other is a supplement, never the identity.
  ///
  /// The enricher uses this to fold a followed guide-detail page (its ★★★, plus any
  /// facts the place's own site omitted) into the main hop before the single DB write.
  public func fillingBlanks(from other: ParsedPage) -> ParsedPage {
    var page = self

    if page.title == nil { page.title = other.title }
    if page.summary == nil { page.summary = other.summary }
    if page.phone == nil { page.phone = other.phone }
    if page.email == nil { page.email = other.email }
    if page.websiteURL == nil { page.websiteURL = other.websiteURL }
    if page.coordinate == nil { page.coordinate = other.coordinate }
    if page.textExcerpt == nil { page.textExcerpt = other.textExcerpt }
    if page.bodyText == nil { page.bodyText = other.bodyText }

    if page.address.street == nil { page.address.street = other.address.street }
    if page.address.locality == nil { page.address.locality = other.address.locality }
    if page.address.region == nil { page.address.region = other.address.region }
    if page.address.postalCode == nil { page.address.postalCode = other.address.postalCode }
    if page.address.country == nil { page.address.country = other.address.country }

    page.imageURLs = appendingUnique(page.imageURLs, other.imageURLs)
    page.socialURLs = appendingUnique(page.socialURLs, other.socialURLs)
    page.links = appendingUnique(page.links, other.links)
    page.schemaTypes = appendingUnique(page.schemaTypes, other.schemaTypes)
    page.openingHours = appendingUnique(page.openingHours, other.openingHours)
    page.evaluations = appendingUnique(evaluations: page.evaluations, other.evaluations)

    return page
  }

  private func appendingUnique<T: Equatable>(_ base: [T], _ extra: [T]) -> [T] {
    var result = base
    for item in extra where !result.contains(item) { result.append(item) }
    return result
  }

  /// Append evaluations not already present, de-duplicated on (source, kind, value)
  /// case-insensitively — the identity `ParseBuilder.addEvaluation` and ADR-0019 §3 use.
  private func appendingUnique(
    evaluations base: [ParsedEvaluation], _ extra: [ParsedEvaluation]
  ) -> [ParsedEvaluation] {
    var result = base
    for candidate in extra {
      let duplicate = result.contains {
        $0.sourceName.caseInsensitiveCompare(candidate.sourceName) == .orderedSame
          && $0.kind == candidate.kind
          && $0.valueText.caseInsensitiveCompare(candidate.valueText) == .orderedSame
      }
      if !duplicate { result.append(candidate) }
    }
    return result
  }
}
