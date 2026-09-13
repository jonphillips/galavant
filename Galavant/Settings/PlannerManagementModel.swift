import Dependencies
import Foundation
import GalavantSchema
import SQLiteData
import Sharing

/// Owns the Settings "Planners" surface: the travel party's voters, with rename
/// and delete so stale or duplicate planner rows (from earlier testing/sync) can
/// be pruned — the "bunch of stale voters" Jon hit on the idea rows (dogfood).
/// The view stays presentation (STYLE thin-views rule).
@MainActor
@Observable
final class PlannerManagementModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll(Planner.order(by: \.displayName)) var planners
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""

  /// This device's own planner — never deletable from here (bind identity in the
  /// Ideas identity sheet instead).
  var currentPlannerID: Planner.ID? { UUID(uuidString: currentPlannerIDString) }

  /// How many ratings a planner has actually cast — the signal for whether a row
  /// is a real voter or a stale empty duplicate.
  func voteCount(for planner: Planner) -> Int {
    interests.filter { $0.plannerID == planner.id && $0.level != nil }.count
  }

  func rename(_ planner: Planner, to name: String) {
    withErrorReporting {
      try database.write { db in
        try Planner.rename(id: planner.id, to: name, in: db)
      }
    }
  }

  /// Delete a planner and the ratings it left. A no-op guard keeps this device's
  /// own planner safe — deleting it would strand the device's identity.
  func delete(_ planner: Planner) {
    guard planner.id != currentPlannerID else { return }
    withErrorReporting {
      try database.write { db in
        try Planner.deletePlanner(id: planner.id, in: db)
      }
    }
  }
}
