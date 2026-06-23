import Foundation
import SQLiteData

@Table
public struct Idea: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = ""
  public var notes = ""
  public var kind: IdeaKind?
  public var regionName: String?
  public var address: String?
  public var phone: String?
  public var latitude: Double?
  public var longitude: Double?
  public var url = ""
  public var visited = false
  /// Opening hours as a plain text block (one line per weekday rule, as the source
  /// stated them). A *fact* about the place (ADR-0016 §2), filled by the field-
  /// supplement ladder or hand-edited; `nil` = unknown, the supplement trigger.
  public var openingHours: String?
  /// How `openingHours` was sourced — stamped so a HITL-scraped or hand-edited value
  /// never reads as authoritative (ADR-0016 §2). `nil` when there are no hours.
  public var hoursProvenance: FactProvenance?
  /// When `openingHours` was last filled/verified — hours rot, so they're dated.
  public var hoursVerifiedAt: Date?
  /// When the app last took the second enrichment hop for this idea (re-fetched its
  /// website for images + facts; M4g). `nil` = not yet enriched — the trigger for a
  /// one-time enrichment pass. Synced so a second device doesn't redo the work.
  public var enrichedAt: Date?
  public var travelPartyID: TravelParty.ID?

  public init(
    id: UUID,
    name: String = "",
    notes: String = "",
    kind: IdeaKind? = nil,
    regionName: String? = nil,
    address: String? = nil,
    phone: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    url: String = "",
    visited: Bool = false,
    openingHours: String? = nil,
    hoursProvenance: FactProvenance? = nil,
    hoursVerifiedAt: Date? = nil,
    enrichedAt: Date? = nil,
    travelPartyID: TravelParty.ID? = nil
  ) {
    self.id = id
    self.name = name
    self.notes = notes
    self.kind = kind
    self.regionName = regionName
    self.address = address
    self.phone = phone
    self.latitude = latitude
    self.longitude = longitude
    self.url = url
    self.visited = visited
    self.openingHours = openingHours
    self.hoursProvenance = hoursProvenance
    self.hoursVerifiedAt = hoursVerifiedAt
    self.enrichedAt = enrichedAt
    self.travelPartyID = travelPartyID
  }
}
