import Foundation
import SQLiteData

extension Trip {
  /// Create a trip attached to the default travel party and return it. A new
  /// `someday` trip is appended to the bottom of the backlog regardless of the
  /// rank carried in `certainty` — the form never has to pick a position.
  public static func create(
    name: String,
    certainty: Certainty = .someday(rank: 0),
    lengthInDays: Int = 7,
    notes: String = "",
    in db: Database
  ) throws -> Trip {
    let partyID = try TravelParty.ensureDefault(in: db).id
    var certainty = certainty
    if certainty.stage == .someday {
      certainty = .someday(rank: try nextSomedayRank(in: db))
    }
    let id = UUID()
    var draft = Trip.Draft(
      id: id, name: name, notes: notes, lengthInDays: lengthInDays, travelPartyID: partyID
    )
    draft.apply(certainty)
    try Trip.insert { draft }.execute(db)
    guard let created = try Trip.find(id).fetchOne(db) else {
      throw TripError.creationFailed
    }
    return created
  }

  /// Persist edits to an existing trip from its form draft + chosen certainty.
  /// Moving a trip *into* the someday backlog from another stage appends it to
  /// the bottom; staying in someday preserves its rank. Sets the party FK and
  /// upserts. (New trips go through `create` instead.)
  public static func update(_ draft: Trip.Draft, certainty: Certainty, in db: Database) throws {
    var draft = draft
    var certainty = certainty
    if certainty.stage == .someday, draft.certaintyStage != .someday {
      certainty = .someday(rank: try nextSomedayRank(in: db))
    }
    draft.apply(certainty)
    draft.travelPartyID = try TravelParty.ensureDefault(in: db).id
    try Trip.upsert { draft }.execute(db)
  }

  /// The next free backlog position — one past the current bottom (or 0 when the
  /// backlog is empty). Filtered in Swift; a household has a handful of trips.
  static func nextSomedayRank(in db: Database) throws -> Int {
    let ranks = try Trip.all.fetchAll(db)
      .filter { $0.certaintyStage == .someday }
      .map(\.somedayRank)
    return (ranks.max() ?? -1) + 1
  }

  /// Persist a new someday-backlog order: each trip's `somedayRank` becomes its
  /// index in `orderedIDs`. Call after a drag-to-reorder.
  public static func reorderSomeday(_ orderedIDs: [Trip.ID], in db: Database) throws {
    for (index, id) in orderedIDs.enumerated() {
      try Trip.find(id).update { $0.somedayRank = index }.execute(db)
    }
  }

  // MARK: - Pure sectioning (functional core)

  /// Split trips into the three certainty sections, each in its own natural
  /// order: someday by backlog rank, targeted by year then quarter, dated by
  /// start date. Pure — no I/O — so it's the densely-tested core.
  public static func sectioned(_ trips: [Trip]) -> TripSections {
    let someday = trips
      .filter { $0.certaintyStage == .someday }
      .sorted { ($0.somedayRank, $0.name.lowercased()) < ($1.somedayRank, $1.name.lowercased()) }
    let targeted = trips
      .filter { $0.certaintyStage == .targeted }
      .sorted { lhs, rhs in
        let l = (lhs.targetYear ?? .max, lhs.targetQuarter?.rawValue ?? 0, lhs.name.lowercased())
        let r = (rhs.targetYear ?? .max, rhs.targetQuarter?.rawValue ?? 0, rhs.name.lowercased())
        return l < r
      }
    let dated = trips
      .filter { $0.certaintyStage == .dated }
      .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    return TripSections(someday: someday, targeted: targeted, dated: dated)
  }
}

/// Trips grouped by certainty stage, each section pre-sorted (see
/// `Trip.sectioned`).
public struct TripSections: Equatable, Sendable {
  public var someday: [Trip]
  public var targeted: [Trip]
  public var dated: [Trip]

  public init(someday: [Trip] = [], targeted: [Trip] = [], dated: [Trip] = []) {
    self.someday = someday
    self.targeted = targeted
    self.dated = dated
  }
}

extension TripIdea {
  /// Pull an idea onto a trip, or return the existing join if it's already
  /// there (idempotent — pulling twice doesn't duplicate). ADR-0004.
  @discardableResult
  public static func pull(
    ideaID: Idea.ID,
    into tripID: Trip.ID,
    status: TripIdeaStatus = .considering,
    in db: Database
  ) throws -> TripIdea {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    if let existing { return existing }
    let id = UUID()
    try TripIdea.insert {
      TripIdea.Draft(id: id, tripID: tripID, ideaID: ideaID, status: status)
    }
    .execute(db)
    guard let created = try TripIdea.find(id).fetchOne(db) else {
      throw TripError.creationFailed
    }
    return created
  }

  /// Advance (or retreat) an idea's lifecycle status on a trip. No-op if the
  /// idea isn't on the trip. Promoting *onto* the shortlist (from a status that
  /// wasn't on it) appends it to the bottom of the shortlist order; demoting
  /// leaves its rank untouched (harmless while off the shortlist).
  public static func setStatus(
    _ status: TripIdeaStatus,
    ideaID: Idea.ID,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    var rank = existing.shortlistRank
    if status.isOnShortlist, !existing.status.isOnShortlist {
      rank = try nextShortlistRank(tripID: tripID, in: db)
    }
    try TripIdea.find(existing.id)
      .update {
        $0.status = status
        $0.shortlistRank = rank
      }
      .execute(db)
  }

  /// Remove an idea from a trip entirely (back to the untouched pool).
  public static func remove(ideaID: Idea.ID, from tripID: Trip.ID, in db: Database) throws {
    try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .delete()
      .execute(db)
  }

  /// One past the current bottom of this trip's shortlist (0 when empty).
  static func nextShortlistRank(tripID: Trip.ID, in db: Database) throws -> Int {
    let ranks = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .filter { $0.status.isOnShortlist }
      .map(\.shortlistRank)
    return (ranks.max() ?? -1) + 1
  }

  /// Persist a new shortlist order: each entry's `shortlistRank` becomes its
  /// index in `orderedIDs` (TripIdea ids). Call after a drag-to-reorder.
  public static func reorderShortlist(_ orderedIDs: [TripIdea.ID], in db: Database) throws {
    for (index, id) in orderedIDs.enumerated() {
      try TripIdea.find(id).update { $0.shortlistRank = index }.execute(db)
    }
  }

  // MARK: - Pure partitioning (functional core)

  /// This trip's shortlist — entries that earned a place (shortlisted onward),
  /// in rank order. Pure.
  public static func shortlist(_ entries: [TripIdea]) -> [TripIdea] {
    entries
      .filter { $0.status.isOnShortlist }
      .sorted { $0.shortlistRank < $1.shortlistRank }
  }

  /// This trip's "considering" maybe-pile — pulled but not yet committed. Pure.
  public static func considering(_ entries: [TripIdea]) -> [TripIdea] {
    entries.filter { $0.status == .considering }
  }
}

public enum TripError: Error {
  case creationFailed
}
