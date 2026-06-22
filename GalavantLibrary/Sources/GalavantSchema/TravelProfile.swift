import Foundation
import SQLiteData

/// A short, editable preference description injected into every model call so AI
/// features reflect this couple's taste (ADR-0015 §3).
///
/// **Shared + per-planner overlay.** `plannerID == nil` is the household profile;
/// a set `plannerID` is that person's overlay. Request construction assembles both
/// ("Jon skews luxury/dining, his wife skews food") — the structured taste seed for
/// future match-prediction.
///
/// **Single real FK** to `TravelParty` (rides the party tree, cascade-deletes).
/// `plannerID` is a loose, optional UUID — no SQL FK (ADR-0007). "Per-planner" is a
/// *subject* dimension, not access control (ADR-0003): both planners see and can edit
/// every row, including each other's overlays.
@Table
public struct TravelProfile: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var travelPartyID: TravelParty.ID
  public var plannerID: Planner.ID?
  public var preferences: String

  public init(
    id: UUID,
    travelPartyID: TravelParty.ID,
    plannerID: Planner.ID? = nil,
    preferences: String = ""
  ) {
    self.id = id
    self.travelPartyID = travelPartyID
    self.plannerID = plannerID
    self.preferences = preferences
  }
}
