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

extension Idea {
  /// Write supplemented opening hours onto an idea with their provenance and a
  /// verified-at stamp (ADR-0016 §2). Blank hours clear the field back to unknown.
  /// No-op on a missing idea.
  public static func setOpeningHours(
    ideaID: Idea.ID,
    hours: String?,
    provenance: FactProvenance,
    verifiedAt: Date,
    in db: Database
  ) throws {
    guard try Idea.find(ideaID).fetchOne(db) != nil else { return }
    let trimmed = hours?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = (trimmed?.isEmpty ?? true) ? nil : trimmed
    try Idea.find(ideaID)
      .update {
        $0.openingHours = #bind(cleaned)
        $0.hoursProvenance = #bind(cleaned == nil ? nil : provenance)
        $0.hoursVerifiedAt = #bind(cleaned == nil ? nil : verifiedAt)
      }
      .execute(db)
  }
}

extension Idea {
  /// The structured weekday hours behind the encoded `structuredHours` column
  /// (ADR-0029 §2). Reading decodes the JSON (malformed → `nil`); writing encodes it,
  /// clearing the column when nothing is asserted.
  public var weeklyHours: WeeklyHours? {
    get { WeeklyHours.decode(structuredHours) }
    set { structuredHours = newValue?.encoded() }
  }
}

extension Idea.Draft {
  /// The structured weekday hours behind the draft's encoded column — the Idea form
  /// edits this, and `Idea.save` persists it (the form stamps `.manual` on a hand
  /// edit). Mirrors `Idea.weeklyHours`.
  public var weeklyHours: WeeklyHours? {
    get { WeeklyHours.decode(structuredHours) }
    set { structuredHours = newValue?.encoded() }
  }
}

extension Idea {
  /// Write structured weekday hours onto an idea with their provenance + a
  /// verified-at stamp — the structured analogue of `setOpeningHours`. Enrichment
  /// calls this fill-blanks-only; the editor calls it with `.manual`, which then wins
  /// over re-enrichment (ADR-0029 §2/§3). An all-unknown value clears the column.
  /// No-op on a missing idea.
  public static func setStructuredHours(
    ideaID: Idea.ID,
    hours: WeeklyHours?,
    provenance: FactProvenance,
    verifiedAt: Date,
    in db: Database
  ) throws {
    guard try Idea.find(ideaID).fetchOne(db) != nil else { return }
    let encoded = hours?.encoded()
    try Idea.find(ideaID)
      .update {
        $0.structuredHours = #bind(encoded)
        // Structured + free-form hours share the one provenance/stamp pair (§2). Only
        // stamp when we actually stored something, so clearing doesn't forge a date.
        if encoded != nil {
          $0.hoursProvenance = #bind(provenance)
          $0.hoursVerifiedAt = #bind(verifiedAt)
        }
      }
      .execute(db)
  }
}

extension Planner {
  /// Create a planner attached to the default travel party and return it.
  public static func create(displayName: String, in db: Database) throws -> Planner {
    let travelPartyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Planner.insert {
      Planner.Draft(Planner(id: id, displayName: displayName, travelPartyID: travelPartyID))
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
        IdeaInterest.Draft(
          IdeaInterest(id: UUID(), ideaID: ideaID, plannerID: plannerID, level: level)
        )
      }
      .execute(db)
    }
  }
}

public enum PoolError: Error {
  case plannerCreationFailed
  case ideaSaveFailed
}
