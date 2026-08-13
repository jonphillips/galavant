import Foundation
import SQLiteData

extension Trip {
  /// A dated trip becomes historical at the first civil instant after its last
  /// itinerary day. The calendar is supplied by the caller so this completion
  /// definition is deterministic in tests and never implicitly reads a device
  /// clock or zone.
  public func isPast(at date: Date, calendar: Calendar) -> Bool {
    guard let startDate,
      let firstInstantAfterTrip = calendar.date(byAdding: .day, value: lengthInDays, to: startDate)
    else { return false }
    return date >= firstInstantAfterTrip
  }

  /// Freeze a trip only after its final successful Calendar read. The inferred
  /// completion lifecycle also rolls scheduled, non-skipped stops into the pool's
  /// visited signal, reusing the existing `markDone` mechanism rather than adding
  /// a second per-stop completion workflow.
  public static func completeCalendarReconciliation(
    tripID: Trip.ID,
    frozenAt: Date,
    in db: Database
  ) throws {
    guard let trip = try Trip.find(tripID).fetchOne(db), trip.calendarReconciliationFrozenAt == nil else {
      return
    }
    let scheduledStopIDs = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .filter { $0.status == .scheduled }
      .map(\.id)
    for stopID in scheduledStopIDs {
      try TripIdea.markDone(stopID: stopID, in: db)
    }
    try Trip.find(tripID)
      .update { $0.calendarReconciliationFrozenAt = #bind(frozenAt) }
      .execute(db)
  }
}
