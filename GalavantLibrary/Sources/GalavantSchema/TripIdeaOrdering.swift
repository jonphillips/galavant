import Foundation
import SQLiteData

extension TripIdea {
  /// One past the bottom of this trip's intra-day order — max `shortlistRank`
  /// across all entries, where a fresh freeform stop appends.
  static func nextStopRank(tripID: Trip.ID, in db: Database) throws -> Int {
    let ranks = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .map(\.shortlistRank)
    return (ranks.max() ?? -1) + 1
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

  /// Persist a new shortlist order after a drag-to-reorder.
  public static func reorderShortlist(_ orderedIDs: [TripIdea.ID], in db: Database) throws {
    for (index, id) in orderedIDs.enumerated() {
      try TripIdea.find(id).update { $0.shortlistRank = index }.execute(db)
    }
  }

  /// The leading run of Anytime stops in an ordered day. These stops need the
  /// negative-rank marker so a subsequent read keeps them ahead of the first
  /// timed/dayparted anchor (ADR-0033).
  public static func leadingAnytimeIDs(
    for orderedIDs: [TripIdea.ID], entries: [TripIdea]
  ) -> Set<TripIdea.ID> {
    let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    return Set(orderedIDs.prefix { id in
      guard let entry = byID[id] else { return false }
      if case .day = entry.schedule { return true }
      return false
    })
  }

  /// Persist a new intra-day order. Leading Anytime rows use negative ranks to
  /// preserve the explicit “before the first timed event” placement without
  /// changing the behavior of untouched historical rows.
  public static func reorderDayStops(
    _ orderedIDs: [TripIdea.ID],
    leadingAnytimeIDs: Set<TripIdea.ID> = [],
    in db: Database
  ) throws {
    for (index, id) in orderedIDs.enumerated() {
      let rank = leadingAnytimeIDs.contains(id)
        ? Double(index - leadingAnytimeIDs.count)
        : Double(index)
      guard let entry = try TripIdea.find(id).fetchOne(db) else { continue }
      let members = try alternativeMembers(containing: entry, in: db)
      for member in members {
        try TripIdea.find(member.id).update { $0.dayRank = rank }.execute(db)
      }
      try normalizeAlternativeMembers(members, in: db)
    }
  }

  /// Move a stop to the end of its current day. The slot's shared rank is
  /// propagated to alternative members so deferring an active choice keeps the
  /// ring in one position.
  public static func moveToEndOfDay(stopID: TripIdea.ID, in db: Database) throws {
    guard let entry = try TripIdea.find(stopID).fetchOne(db), let day = entry.dayNumber else {
      return
    }
    let dayEntries = try TripIdea
      .where { $0.tripID.eq(entry.tripID) }
      .fetchAll(db)
      .filter { $0.dayNumber == day }
    let rank = (dayEntries.map(\.dayRank).max() ?? entry.dayRank) + 1
    let members = try alternativeMembers(containing: entry, in: db)
    for member in members {
      try TripIdea.find(member.id).update { $0.dayRank = #bind(rank) }.execute(db)
    }
    try normalizeAlternativeMembers(members, in: db)
  }
}
