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
    guard try TripIdea.find(stopID).fetchOne(db) != nil else { return }
    let schedule = commitment.schedule(on: dayNumber)
    switch schedule {
    case let .day(day):
      try TripIdea.find(stopID)
        .update {
          $0.pinnedDate = #bind(commitment.pinnedDate)
          $0.dayNumber = #bind(day)
          $0.dayPart = #bind(nil)
          $0.startTime = #bind(nil)
          $0.endTime = #bind(nil)
          $0.status = #bind(.scheduled)
        }
        .execute(db)
    case let .timed(day, start, end):
      try TripIdea.find(stopID)
        .update {
          $0.pinnedDate = #bind(commitment.pinnedDate)
          $0.dayNumber = #bind(day)
          $0.dayPart = #bind(nil)
          $0.startTime = #bind(start)
          $0.endTime = #bind(end)
          $0.status = #bind(.scheduled)
        }
        .execute(db)
    case .unscheduled, .daypart:
      return
    }
  }
}
