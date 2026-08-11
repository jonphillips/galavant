import Foundation
import SQLiteData

extension TravelProfile {
  // MARK: - Write ops (ADR-0015 §3)

  /// Set (or replace) the shared household profile or a planner-specific overlay.
  /// `plannerID == nil` targets the shared row; a set `plannerID` targets that
  /// planner's overlay. At most one row per `(travelPartyID, plannerID)` pair —
  /// re-setting replaces rather than appending. Returns the profile's id.
  @discardableResult
  public static func setPreferences(
    _ preferences: String,
    travelPartyID: TravelParty.ID,
    plannerID: Planner.ID? = nil,
    in db: Database
  ) throws -> TravelProfile.ID {
    let existing: TravelProfile?
    if let plannerID {
      existing = try TravelProfile
        .where { $0.travelPartyID.eq(travelPartyID) && $0.plannerID.eq(plannerID) }
        .fetchOne(db)
    } else {
      existing = try TravelProfile
        .where { $0.travelPartyID.eq(travelPartyID) && $0.plannerID.is(nil) }
        .fetchOne(db)
    }
    if let existing {
      try TravelProfile.find(existing.id)
        .update { $0.preferences = #bind(preferences) }
        .execute(db)
      return existing.id
    }
    let id = UUID()
    try TravelProfile.insert {
      TravelProfile.Draft(
        TravelProfile(
          id: id,
          travelPartyID: travelPartyID,
          plannerID: plannerID,
          preferences: preferences
        )
      )
    }
    .execute(db)
    return id
  }

  /// Remove a profile row (shared or per-planner). No-op if it doesn't exist.
  public static func removeProfile(
    travelPartyID: TravelParty.ID,
    plannerID: Planner.ID? = nil,
    in db: Database
  ) throws {
    if let plannerID {
      try TravelProfile
        .where { $0.travelPartyID.eq(travelPartyID) && $0.plannerID.eq(plannerID) }
        .delete()
        .execute(db)
    } else {
      try TravelProfile
        .where { $0.travelPartyID.eq(travelPartyID) && $0.plannerID.is(nil) }
        .delete()
        .execute(db)
    }
  }
}

extension TravelProfile {
  // MARK: - Read-model helpers (pure, ADR-0015 §3)

  /// Assemble "shared household profile + this planner's overlay" from a
  /// pre-fetched array. When `plannerID` is nil, returns only the shared profile.
  /// Non-empty parts are joined with a blank line so the prompt has natural
  /// paragraph breaks. Pure — no I/O.
  public static func assembledProfile(
    travelPartyID: TravelParty.ID,
    plannerID: Planner.ID?,
    from profiles: [TravelProfile]
  ) -> String {
    let shared = profiles
      .first { $0.travelPartyID == travelPartyID && $0.plannerID == nil }?
      .preferences ?? ""
    guard let plannerID else { return shared }
    let overlay = profiles
      .first { $0.travelPartyID == travelPartyID && $0.plannerID == plannerID }?
      .preferences ?? ""
    return [shared, overlay].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
}
