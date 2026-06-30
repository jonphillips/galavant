import Foundation
import SQLiteData

@Table
public struct Idea: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = ""
  /// A short descriptor of the place — the page's JSON-LD / `og:description` summary,
  /// de-marketed (ADR-0026). A *fact* derived from the source: fill-blanks-only on a
  /// re-capture, like the other page-derived facts. Distinct from `notes`, which is the
  /// user's own free space. Empty when the page carried no description.
  public var description = ""
  /// The user's own free-text notes — theirs to grow. **Additive** on re-capture
  /// (ADR-0026): a fresh capture appends rather than replacing, so a hand-written note
  /// (e.g. "Apple Maps sends you to the service entrance — real door is round back")
  /// survives. Distinct from the page-derived `description`.
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
  /// Apple Maps' persistent place identity (`MKMapItem.identifier.rawValue`), when the
  /// capture resolved to a real Maps POI. The dedup key (ADR-0019): a re-share of the
  /// same place is recognized by this and supplements the existing idea instead of
  /// duplicating it. `nil` for geocoded/scraped/freeform locations — those never
  /// auto-merge. Not a `UNIQUE` column: dedup is an app-level lookup, not a schema
  /// invariant (CloudKit can't enforce cross-device uniqueness).
  public var mapItemIdentifier: String?
  public var travelPartyID: TravelParty.ID?

  public init(
    id: UUID,
    name: String = "",
    description: String = "",
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
    mapItemIdentifier: String? = nil,
    travelPartyID: TravelParty.ID? = nil
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
    self.visited = visited
    self.openingHours = openingHours
    self.hoursProvenance = hoursProvenance
    self.hoursVerifiedAt = hoursVerifiedAt
    self.enrichedAt = enrichedAt
    self.mapItemIdentifier = mapItemIdentifier
    self.travelPartyID = travelPartyID
  }
}
