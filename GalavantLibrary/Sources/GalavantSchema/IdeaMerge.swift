import Foundation

extension Idea {
  /// Supplement this idea with newly captured facts, **fill-blanks-only** (ADR-0019 §3):
  /// never overwrite a value already present — a deliberate edit or a verified fact
  /// stands — and back-fill the Apple Maps identity if it was missing (so a re-share
  /// stamps the dedup key onto a pre-ADR-0019 idea). Facts only; judgments
  /// (`IdeaEvaluation`) and the header image are handled by their own siblings.
  ///
  /// Pure — the capture merge path's whole fact-merge in one place, unit-testable
  /// without a database.
  public func supplemented(
    name: String,
    description: String = "",
    notes: String = "",
    kind: IdeaKind?,
    regionName: String?,
    address: String?,
    phone: String?,
    latitude: Double?,
    longitude: Double?,
    url: String,
    mapItemIdentifier: String?,
    openingHours: String? = nil,
    hoursProvenance: FactProvenance? = nil,
    hoursVerifiedAt: Date? = nil
  ) -> Idea {
    var merged = self
    if merged.name.isEmpty, !name.isEmpty { merged.name = name }
    // `description` is a page-derived fact — fill-blanks-only, like the rest below.
    if merged.description.isEmpty, !description.isEmpty { merged.description = description }
    // `notes` is the user's space — additive (ADR-0026), the one field that grows on a
    // re-capture rather than standing pat.
    merged.notes = Self.appendingNotes(existing: merged.notes, addition: notes)
    if merged.kind == nil { merged.kind = kind }
    if merged.regionName == nil { merged.regionName = regionName }
    if merged.address == nil { merged.address = address }
    if merged.phone == nil { merged.phone = phone }
    if merged.latitude == nil { merged.latitude = latitude }
    if merged.longitude == nil { merged.longitude = longitude }
    if merged.url.isEmpty, !url.isEmpty { merged.url = url }
    if merged.mapItemIdentifier == nil { merged.mapItemIdentifier = mapItemIdentifier }
    if merged.openingHours == nil, let openingHours {
      merged.openingHours = openingHours
      merged.hoursProvenance = hoursProvenance
      merged.hoursVerifiedAt = hoursVerifiedAt
    }
    return merged
  }

  /// Append captured notes to existing notes, additively (ADR-0026): notes are the
  /// user's to grow, so a re-capture adds to them rather than replacing. A blank
  /// addition is a no-op; an addition already present verbatim isn't duplicated; a new
  /// note is separated from the existing block by a blank line. Pure — unit-testable
  /// without a database.
  public static func appendingNotes(existing: String, addition: String) -> String {
    let add = addition.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !add.isEmpty else { return existing }
    let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return add }
    guard base.range(of: add) == nil else { return base }
    return base + "\n\n" + add
  }
}
