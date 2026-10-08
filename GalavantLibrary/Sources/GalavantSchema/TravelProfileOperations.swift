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
  // MARK: - Prompt rendering (pure, ADR-0015 §3)

  /// Render the household profile and each known planner's overlay as stable
  /// prompt lines. Empty text and overlays for missing planners are omitted.
  public static func promptLines(
    travelPartyID: TravelParty.ID,
    profiles: [TravelProfile],
    planners: [Planner]
  ) -> [String] {
    func trimmed(_ text: String) -> String {
      text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lines: [String] = []
    if let shared = profiles.first(where: { $0.travelPartyID == travelPartyID && $0.plannerID == nil }) {
      let preferences = trimmed(shared.preferences)
      if !preferences.isEmpty { lines.append("Our travel taste: \(preferences)") }
    }

    let plannerByID = Dictionary(planners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let overlays = profiles.compactMap { profile -> (Planner, String)? in
      guard profile.travelPartyID == travelPartyID,
            let plannerID = profile.plannerID,
            let planner = plannerByID[plannerID]
      else { return nil }
      let preferences = trimmed(profile.preferences)
      return preferences.isEmpty ? nil : (planner, preferences)
    }.sorted { lhs, rhs in
      if lhs.0.displayName == rhs.0.displayName { return lhs.0.id.uuidString < rhs.0.id.uuidString }
      return lhs.0.displayName < rhs.0.displayName
    }
    lines.append(contentsOf: overlays.map { "\($0.0.displayName)'s taste: \($0.1)" })
    return lines
  }
}
