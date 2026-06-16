import Foundation
import SQLiteData

extension Idea {
  /// Save the capture form's draft: default its id and travel party, upsert it,
  /// and reconcile its tags to exactly `tagNames` (reuse-or-create each by name,
  /// then add/remove only the join deltas). Returns the idea's id. The single
  /// save path for the New/Edit Idea form — the model just calls this.
  @discardableResult
  public static func save(
    _ draft: Idea.Draft,
    tagNames: [String],
    in db: Database
  ) throws -> Idea.ID {
    var saving = draft
    saving.travelPartyID = try TravelParty.ensureDefault(in: db).id
    // Upsert handles new-or-existing; RETURNING hands back the id (DB-generated
    // for a new row), so we never reconstruct the draft to inject one.
    guard let ideaID = try Idea.upsert { saving }.returning(\.id).fetchOne(db) else {
      throw PoolError.ideaSaveFailed
    }

    let desired = try Set(tagNames.map { try Tag.findOrCreate(named: $0, in: db).id })
    let existing = try Set(
      IdeaTag.where { $0.ideaID.eq(ideaID) }.fetchAll(db).map(\.tagID)
    )
    for tagID in desired.subtracting(existing) {
      try IdeaTag.add(tagID: tagID, to: ideaID, in: db)
    }
    for tagID in existing.subtracting(desired) {
      try IdeaTag.remove(tagID: tagID, from: ideaID, in: db)
    }
    return ideaID
  }
}

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
  case ideaSaveFailed
}
