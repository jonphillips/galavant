import Foundation
import GalavantSchema
import Testing

@Suite struct CalendarIgnoredEventTests {
  private let timeZone = TimeZone(identifier: "Europe/Rome")!

  private var trip: Trip {
    Trip(id: UUID(), name: "Rome", startDate: date(2026, 8, 12), lengthInDays: 3)
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
  }

  private func event() -> CalendarObservedEvent {
    CalendarObservedEvent(
      id: "local-event",
      eventIdentifier: "local-event",
      externalIdentifier: "shared-event",
      title: "Call Tax Advisor",
      temporal: .absolute(
        start: date(2026, 8, 12), end: date(2026, 8, 12).addingTimeInterval(3600),
        timeZone: timeZone),
      calendarTitle: "Family")
  }

  @Test func ignoredIdentityIsDeterministicPerTripAndSource() throws {
    let trip = self.trip
    let first = try #require(CalendarIgnoredEvent(
      tripID: trip.id, event: event(), ignoredAt: .distantPast))
    let second = try #require(CalendarIgnoredEvent(
      tripID: trip.id, event: event(), ignoredAt: .distantFuture))
    #expect(first.id == second.id)
    #expect(first.sourceIdentityHash == second.sourceIdentityHash)
    #expect(first.ignoredAt == .distantPast)
  }

  @Test func ignoredEventIsFilteredBeforeMatching() throws {
    let trip = self.trip
    let observed = event()
    let ignored = try #require(CalendarIgnoredEvent(
      tripID: trip.id, event: observed, ignoredAt: .now))
    let input = CalendarIngestedEvent(event: observed, itineraryTimeZone: timeZone)

    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip,
      plan: TripPlan(entries: [], ideasByID: [:], lengthInDays: 3),
      ignoredSourceIdentityHashes: [ignored.sourceIdentityHash])

    #expect(candidates.isEmpty)
  }

  @Test func ignoredEventSupersedesExistingConstraintWithoutDroppingLocalBinding() throws {
    let trip = self.trip
    let observed = event()
    let ignored = try #require(CalendarIgnoredEvent(
      tripID: trip.id, event: observed, ignoredAt: .now))
    let constraint = try #require(CalendarTripConstraint(
      tripID: trip.id, event: observed, projection: .day(1, timeZone: timeZone)))
    let binding = CalendarLinkedConstraint(
      constraintID: constraint.id, eventID: observed.id, calendarID: "family",
      sourceExternalIdentifier: observed.externalIdentifier!)
    let candidate = CalendarReconciliationCandidate(
      input: CalendarIngestedEvent(event: observed, itineraryTimeZone: timeZone),
      result: .unmatched,
      projection: .day(1, timeZone: timeZone),
      temporalContext: nil)

    let plan = CalendarReconciliation.constraintPlan(
      candidates: [candidate], tripID: trip.id, calendarID: "family",
      localState: CalendarReconciliationLocalState(linkedConstraints: [binding]),
      existingConstraints: [constraint],
      ignoredSourceIdentityHashes: [ignored.sourceIdentityHash])

    #expect(plan.upserts.isEmpty)
    #expect(plan.deletions == [constraint.id])
    #expect(plan.localState.linkedConstraints == [binding])
  }
}
