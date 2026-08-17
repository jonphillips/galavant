import Foundation
import SQLiteData

extension TripIdea {
  /// Apply an already-validated Calendar commitment to a linked stop.
  /// This is the Calendar-authoritative time writer: it updates
  /// the synced display cache while the EventKit binding itself remains local in
  /// `CalendarReconciliationHistoryStore`. It intentionally preserves the user's
  /// free-form booking details; Calendar supplied time, not those notes.
  public static func applyCalendarCommitment(
    _ commitment: CalendarCommitment,
    stopID: TripIdea.ID,
    dayNumber: DayNumber,
    in db: Database
  ) throws {
    guard let entry = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try TripIdea.alternativeMembers(containing: entry, in: db)
    guard TripIdea.effectiveActiveMember(in: members)?.id == stopID else { return }
    let schedule = commitment.schedule(on: dayNumber)
    switch schedule {
    case let .day(day):
      try TripIdea.find(stopID)
        .update {
          $0.pinnedDate = #bind(commitment.pinnedDate)
        }
        .execute(db)
      try TripIdea.updateSharedSlot(members: members, status: .scheduled, schedule: .day(day), in: db)
    case let .timed(day, start, end):
      try TripIdea.find(stopID)
        .update {
          $0.pinnedDate = #bind(commitment.pinnedDate)
        }
        .execute(db)
      try TripIdea.updateSharedSlot(
        members: members,
        status: .scheduled,
        schedule: .timed(day, start: start, end: end),
        in: db)
    case .unscheduled, .daypart:
      return
    }
  }

  public static func removeCalendarPin(stopID: TripIdea.ID, in db: Database) throws {
    try TripIdea.find(stopID)
      .update { $0.pinnedDate = #bind(nil as Date?) }
      .execute(db)
  }

  /// Reverts a Calendar-linked stop to Anytime on its current day when the
  /// binding is removed. The pre-link manual clock is not stored, so restoring
  /// it would be guesswork; clearing the Calendar-derived schedule is explicit.
  /// Alternative-ring members receive the same day-only schedule as the active
  /// member so the shared slot remains consistent.
  public static func revertCalendarSchedule(stopID: TripIdea.ID, in db: Database) throws {
    guard let entry = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try TripIdea.alternativeMembers(containing: entry, in: db)
    guard TripIdea.effectiveActiveMember(in: members)?.id == stopID else { return }
    try TripIdea.find(stopID)
      .update { $0.pinnedDate = #bind(nil as Date?) }
      .execute(db)
    guard let day = entry.dayNumber else { return }
    try TripIdea.updateSharedSlot(
      members: members, status: .scheduled, schedule: .day(day), in: db)
  }
}
