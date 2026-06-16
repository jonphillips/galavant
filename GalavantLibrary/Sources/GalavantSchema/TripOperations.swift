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

  /// The in-play trips for the Ideas-screen capsules (the "launchpad"): every
  /// `dated` and `targeted` trip, plus the single top-of-backlog `someday` —
  /// derived from the certainty lifecycle, never filter MRU (which lingers
  /// stale). Ordered dated → targeted → someday, matching the sections.
  ///
  /// `Trip` carries no touch timestamp, so "most-recently-touched someday" is
  /// approximated by the top of the someday backlog (lowest `somedayRank`); when
  /// touch tracking exists this can sharpen without changing callers.
  public static func activeCapsules(_ trips: [Trip]) -> [Trip] {
    let sections = sectioned(trips)
    return sections.dated + sections.targeted + Array(sections.someday.prefix(1))
  }
}

extension Trip {
  /// The calendar date day `number` (1-based) lands on when the trip is dated;
  /// nil for undated trips. The itinerary is day-relative — this is derived for
  /// display only, never stored (docs/trip-time-model.md §2).
  public func date(forDay number: Int) -> Date? {
    guard let startDate else { return nil }
    return Calendar.current.date(byAdding: .day, value: number - 1, to: startDate)
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

  /// Place a shortlisted idea onto a day (or re-place an already-scheduled one):
  /// set `status = .scheduled` and write the schedule columns in one update.
  /// No-op if the idea isn't on the trip.
  public static func schedule(
    _ schedule: Schedule,
    ideaID: Idea.ID,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    // A nil day would violate the `.scheduled ⇔ dayNumber != nil` invariant —
    // callers wanting to clear a day use `unschedule` instead.
    guard var updated = existing, schedule.dayNumber != nil else { return }
    updated.status = .scheduled
    updated.apply(schedule)
    try TripIdea.find(updated.id)
      .update {
        $0.status = #bind(updated.status)
        $0.dayNumber = #bind(updated.dayNumber)
        $0.dayPart = #bind(updated.dayPart)
        $0.startTime = #bind(updated.startTime)
        $0.endTime = #bind(updated.endTime)
      }
      .execute(db)
  }

  /// Commit a stop to the itinerary without a day yet — the "To Be Scheduled"
  /// bucket. Status becomes `.scheduled` with the day columns cleared; place it
  /// on a day later with `schedule(_:)`. No-op if the idea isn't on the trip.
  public static func scheduleUnplaced(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .update {
        $0.status = #bind(.scheduled)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
      }
      .execute(db)
  }

  /// Pull a scheduled stop back to the shortlist: clear its schedule columns and
  /// set `status = .shortlisted` (it keeps its `shortlistRank`). No-op if the
  /// idea isn't on the trip.
  public static func unschedule(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .update {
        $0.status = #bind(.shortlisted)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
      }
      .execute(db)
  }

  /// Mark a stop done after the trip and feed that back to the pool: flip the
  /// idea's `visited` flag in the same transaction (ADR-0004). No-op if the
  /// idea isn't on the trip.
  public static func markDone(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    try TripIdea.find(existing.id).update { $0.status = #bind(.done) }.execute(db)
    try Idea.find(ideaID).update { $0.visited = #bind(true) }.execute(db)
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

  /// Scheduled stops not yet placed on a day — the "To Be Scheduled" bucket that
  /// sits atop the itinerary, in shortlist-rank order. Pure.
  public static func toBeScheduled(_ entries: [TripIdea]) -> [TripIdea] {
    entries
      .filter { $0.status == .scheduled && $0.dayNumber == nil }
      .sorted { $0.shortlistRank < $1.shortlistRank }
  }

  /// Lay the `scheduled` stops out across days 1…`lengthInDays`. Every day is
  /// present (empty days included, so the view can offer them as drop targets);
  /// each day's stops are ordered by their schedule's intra-day key, then
  /// `shortlistRank` as a stable tiebreak. Stops whose day falls outside
  /// 1…`lengthInDays` (e.g. the trip was shortened) collapse onto the last day
  /// so nothing silently vanishes. Pure — the densely-tested core.
  public static func itinerary(_ entries: [TripIdea], lengthInDays: Int) -> [ItineraryDay] {
    let days = Swift.max(1, lengthInDays)
    let scheduled = entries.filter { $0.status == .scheduled && $0.dayNumber != nil }
    return (1...days).map { number in
      let stops = scheduled
        .filter { entry in
          let day = entry.dayNumber ?? 1
          return Swift.min(Swift.max(day, 1), days) == number
        }
        .sorted {
          ($0.schedule.intraDaySort, $0.shortlistRank)
            < ($1.schedule.intraDaySort, $1.shortlistRank)
        }
      return ItineraryDay(number: number, stops: stops)
    }
  }
}

/// One day of a trip's itinerary: its 1-based number and the stops placed on it,
/// pre-ordered (see `TripIdea.itinerary`).
public struct ItineraryDay: Equatable, Identifiable, Sendable {
  public var number: Int
  public var stops: [TripIdea]
  public var id: Int { number }

  public init(number: Int, stops: [TripIdea] = []) {
    self.number = number
    self.stops = stops
  }
}

public enum TripError: Error {
  case creationFailed
}
