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
  /// the independent trip-level roll-up runs from the app lifecycle. Freezing is
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

  /// Apply the pool feedback for one completed trip atomically. Stops and their
  /// execution overlay remain historical facts; only pool ideas gain Visited.
  public static func rollUpVisited(
    tripID: Trip.ID,
    now: Date,
    calendar: Calendar,
    in db: Database
  ) throws {
    guard let trip = try Trip.find(tripID).fetchOne(db),
      trip.visitedRolledUpAt == nil,
      trip.isPast(at: now, calendar: calendar)
    else { return }

    let stops = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let ideaIDs = VisitedRollup.ideaIDs(
      for: trip, tripIdeas: stops, now: now, calendar: calendar)
    for ideaID in ideaIDs {
      try Idea.find(ideaID).update { $0.visited = #bind(true) }.execute(db)
    }
    try Trip.find(tripID)
      .update { $0.visitedRolledUpAt = #bind(now) }
      .execute(db)
  }
}

/// Pure selection rules for inferring pool visits from a completed trip.
public enum VisitedRollup {
  public static func ideaIDs(
    for trip: Trip,
    tripIdeas: [TripIdea],
    now: Date,
    calendar: Calendar
  ) -> Set<Idea.ID> {
    guard trip.visitedRolledUpAt == nil, trip.isPast(at: now, calendar: calendar) else {
      return []
    }
    return Set(tripIdeas.compactMap { stop in
      guard stop.status == .scheduled,
        stop.schedule != .unscheduled,
        stop.skippedAt == nil,
        let ideaID = stop.ideaID,
        stop.alternativeGroupID == nil || stop.completedAt != nil
      else { return nil }
      return ideaID
    })
  }
}
