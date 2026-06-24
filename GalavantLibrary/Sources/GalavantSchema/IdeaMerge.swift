import Foundation

extension Idea {
  /// Supplement this idea with newly captured facts, **fill-blanks-only** (ADR-0019 §3):
  /// never overwrite a value already present — a deliberate edit or a verified fact
  /// stands — and back-fill the Apple Maps identity if it was missing (so a re-share
  /// stamps the dedup key onto a pre-ADR-0019 idea). Facts only; judgments
  /// (`IdeaEvaluation`) and the header image are handled by their own siblings, and
  /// `openingHours`/provenance are left to the supplement ladder (ADR-0016).
  ///
  /// Pure — the capture merge path's whole fact-merge in one place, unit-testable
  /// without a database.
  public func supplemented(
    name: String,
    kind: IdeaKind?,
    regionName: String?,
    address: String?,
    phone: String?,
    latitude: Double?,
    longitude: Double?,
    url: String,
    mapItemIdentifier: String?
  ) -> Idea {
    var merged = self
    if merged.name.isEmpty, !name.isEmpty { merged.name = name }
    if merged.kind == nil { merged.kind = kind }
    if merged.regionName == nil { merged.regionName = regionName }
    if merged.address == nil { merged.address = address }
    if merged.phone == nil { merged.phone = phone }
    if merged.latitude == nil { merged.latitude = latitude }
    if merged.longitude == nil { merged.longitude = longitude }
    if merged.url.isEmpty, !url.isEmpty { merged.url = url }
    if merged.mapItemIdentifier == nil { merged.mapItemIdentifier = mapItemIdentifier }
    return merged
  }
}
