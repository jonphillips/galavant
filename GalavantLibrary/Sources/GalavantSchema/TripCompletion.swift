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

  /// Freeze a trip's Calendar authority after its final successful read: past this
  /// boundary, later Calendar edits no longer rewrite the trip (ADR-0034 §12). This
  /// deliberately does **not** roll scheduled stops into the pool's visited signal —
  /// that trip-level done→visited rollup is its own lifecycle feature (see
  /// docs/CURRENT_HANDOFF.md), not a side effect of a Calendar read. Freezing is
  /// idempotent: the first successful post-trip read wins the boundary.
  public static func completeCalendarReconciliation(
    tripID: Trip.ID,
    frozenAt: Date,
    in db: Database
  ) throws {
    guard let trip = try Trip.find(tripID).fetchOne(db), trip.calendarReconciliationFrozenAt == nil else {
      return
    }
    try Trip.find(tripID)
      .update { $0.calendarReconciliationFrozenAt = #bind(frozenAt) }
      .execute(db)
  }
}
