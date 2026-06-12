import Foundation
import SQLiteData

extension Planner {
  /// Create a planner attached to the default travel party and return it.
  public static func create(displayName: String, in db: Database) throws -> Planner {
    let travelPartyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Planner.insert {
      Planner.Draft(id: id, displayName: displayName, travelPartyID: travelPartyID)
    }
    .execute(db)
    guard let created = try Planner.find(id).fetchOne(db) else {
      throw PoolError.plannerCreationFailed
    }
    return created
  }
}

extension IdeaInterest {
  /// Set (or clear) a planner's interest level for an idea — one row per
  /// (idea, planner). Passing `nil` level with an empty note removes the row.
  public static func set(
    level: Interest?,
    ideaID: Idea.ID,
    plannerID: Planner.ID,
    in db: Database
  ) throws {
    let existing = try IdeaInterest
      .where { $0.ideaID.eq(ideaID) && $0.plannerID.eq(plannerID) }
      .fetchOne(db)
    if let existing {
      if level == nil, existing.note.isEmpty {
        try IdeaInterest.find(existing.id).delete().execute(db)
      } else {
        try IdeaInterest.find(existing.id)
          .update { $0.level = level }
          .execute(db)
      }
    } else if level != nil {
      try IdeaInterest.insert {
        IdeaInterest.Draft(id: UUID(), ideaID: ideaID, plannerID: plannerID, level: level)
      }
      .execute(db)
    }
  }
}

public enum PoolError: Error {
  case plannerCreationFailed
}
