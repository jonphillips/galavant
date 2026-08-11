import Foundation
import SQLiteData

extension TripIdea {
  /// Apply an ordinary, already-validated Calendar commitment to a linked stop.
  /// This is the only Slice 2 writer for Calendar-authoritative time: it updates
  /// the synced display cache while the EventKit binding itself remains local in
  /// `CalendarReconciliationHistoryStore`. It intentionally preserves the user's
  /// free-form booking details; Calendar supplied time, not those notes.
  public static func applyCalendarCommitment(
    _ commitment: CalendarCommitment,
    stopID: TripIdea.ID,
    in db: Database,
    calendar: Calendar = .current
  ) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db),
      let startDate = try Trip.find(existing.tripID).fetchOne(db)?.startDate
    else { return }
    let day = Trip.dayNumber(forPinnedDate: commitment.pinnedDate, startDate: startDate)
    let schedule = commitment.schedule(on: day, calendar: calendar)
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
