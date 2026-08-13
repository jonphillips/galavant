import Foundation
import SQLiteData

/// The provider facts from one confirmed capture. This is the single value boundary
/// for the capture merge: web capture and a recommendation's chosen Maps result both
/// resolve through it, so identity dedup and fill-blanks preservation cannot drift.
public struct IdeaCapture: Equatable, Sendable {
  public var id: Idea.ID?
  public var name: String
  public var description: String
  public var notes: String
  public var kind: IdeaKind?
  public var regionName: String?
  public var address: String?
  public var phone: String?
  public var latitude: Double?
  public var longitude: Double?
  public var url: String
  public var mapItemIdentifier: String?
  public var openingHours: String?
  public var hoursProvenance: FactProvenance?
  public var hoursVerifiedAt: Date?

  public init(
    id: Idea.ID? = nil,
    name: String,
    description: String = "",
    notes: String = "",
    kind: IdeaKind? = nil,
    regionName: String? = nil,
    address: String? = nil,
    phone: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    url: String = "",
    mapItemIdentifier: String? = nil,
    openingHours: String? = nil,
    hoursProvenance: FactProvenance? = nil,
    hoursVerifiedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.notes = notes
    self.kind = kind
    self.regionName = regionName
    self.address = address
    self.phone = phone
    self.latitude = latitude
    self.longitude = longitude
    self.url = url
    self.mapItemIdentifier = mapItemIdentifier
    self.openingHours = openingHours
    self.hoursProvenance = hoursProvenance
    self.hoursVerifiedAt = hoursVerifiedAt
  }
}

/// The durable pool identity selected by the capture merge, plus whether the capture
/// minted it. Sibling writers use `isNew` to avoid replacing an established header.
public struct IdeaCaptureResolution: Equatable, Sendable {
  public let ideaID: Idea.ID
  public let isNew: Bool

  public init(ideaID: Idea.ID, isNew: Bool) {
    self.ideaID = ideaID
    self.isNew = isNew
  }
}

extension Idea {
  /// Insert a confirmed capture, or supplement the pool idea already identified by
  /// its Apple Maps identity. A missing identity deliberately never auto-merges
  /// (ADR-0019); a fuzzy candidate becomes a shared `Idea` only after this path.
  @discardableResult
  public static func resolveCapture(
    _ capture: IdeaCapture,
    travelPartyID: TravelParty.ID,
    in db: Database
  ) throws -> IdeaCaptureResolution {
    let existing: Idea? = capture.mapItemIdentifier.flatMap { identifier in
      try? Idea.where { $0.mapItemIdentifier.eq(identifier) }.fetchOne(db)
    }
    if let existing {
      let merged = existing.supplemented(
        name: capture.name,
        description: capture.description,
        notes: capture.notes,
        kind: capture.kind,
        regionName: capture.regionName,
        address: capture.address,
        phone: capture.phone,
        latitude: capture.latitude,
        longitude: capture.longitude,
        url: capture.url,
        mapItemIdentifier: capture.mapItemIdentifier,
        openingHours: capture.openingHours,
        hoursProvenance: capture.hoursProvenance,
        hoursVerifiedAt: capture.hoursVerifiedAt
      )
      try Idea.upsert { Idea.Draft(merged) }.execute(db)
      return IdeaCaptureResolution(ideaID: existing.id, isNew: false)
    }

    let ideaID = capture.id ?? UUID()
    try Idea.insert {
      Idea.Draft(
        Idea(
          id: ideaID,
          name: capture.name,
          description: capture.description,
          notes: capture.notes,
          kind: capture.kind,
          regionName: capture.regionName,
          address: capture.address,
          phone: capture.phone,
          latitude: capture.latitude,
          longitude: capture.longitude,
          url: capture.url,
          openingHours: capture.openingHours,
          hoursProvenance: capture.hoursProvenance,
          hoursVerifiedAt: capture.hoursVerifiedAt,
          mapItemIdentifier: capture.mapItemIdentifier,
          travelPartyID: travelPartyID
        )
      )
    }
    .execute(db)
    return IdeaCaptureResolution(ideaID: ideaID, isNew: true)
  }

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
