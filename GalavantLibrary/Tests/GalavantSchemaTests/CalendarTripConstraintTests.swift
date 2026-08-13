@testable import GalavantSchema
import CustomDump
import Dependencies
import Foundation
import GRDB
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct CalendarTripConstraintTests {
  @Dependency(\.defaultDatabase) private var database

  private let tripID = UUID()
  private let calendarID = "shared-calendar"
  private let timeZone = TimeZone(identifier: "Europe/Rome")!

  @Test func unmatchedEventBecomesSharedTripConstraint() throws {
    let event = observedEvent(title: "Call Tax Advisor", identifier: "local-a")
    let plan = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())

    let constraint = try #require(plan.upserts.first)
    #expect(constraint.title == "Call Tax Advisor")
    #expect(constraint.dayNumber == 2)
    #expect(constraint.startTime == "10:00")
    #expect(constraint.endTime == "11:00")
    expectNoDifference(
      plan.localState.linkedConstraints,
      [CalendarLinkedConstraint(
        constraintID: constraint.id,
        eventID: "local-a",
        calendarID: calendarID,
        sourceExternalIdentifier: "server-event")])
  }

  @Test func twoDevicesDeriveOneConstraintIdentity() throws {
    let first = CalendarReconciliation.constraintPlan(
      candidates: [candidate(observedEvent(identifier: "device-a"))],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let second = CalendarReconciliation.constraintPlan(
      candidates: [candidate(observedEvent(identifier: "device-b"))],
      tripID: tripID,
      calendarID: "other-device-calendar",
      localState: CalendarReconciliationLocalState())

    #expect(try #require(first.upserts.first).id == second.upserts.first?.id)
    #expect(first.upserts.first?.sourceIdentityHash == second.upserts.first?.sourceIdentityHash)
  }

  @Test func replacementLocalIdentifierHealsAndUpdatesConstraint() throws {
    let firstEvent = observedEvent(identifier: "old-local-id")
    let first = CalendarReconciliation.constraintPlan(
      candidates: [candidate(firstEvent)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let original = try #require(first.upserts.first)
    let moved = observedEvent(identifier: "new-local-id", hour: 14)

    let updated = CalendarReconciliation.constraintPlan(
      candidates: [candidate(moved)],
      tripID: tripID,
      calendarID: calendarID,
      localState: first.localState,
      deletedEventIDs: ["old-local-id"])

    let constraint = try #require(updated.upserts.first)
    #expect(constraint.id == original.id)
    #expect(constraint.startTime == "14:00")
    #expect(updated.deletions.isEmpty)
    #expect(updated.localState.linkedConstraints.first?.eventID == "new-local-id")
  }

  @Test func ambiguousNewEventDoesNotBecomeDuplicateConstraint() {
    let event = observedEvent()
    let stop = ResolvedStop(
      entry: TripIdea(id: UUID(), tripID: tripID, ideaID: nil, inlineTitle: "Tax Advisor"),
      content: .freeform(title: "Tax Advisor", note: nil))
    let proposed = candidate(event, result: .proposed(stop, basis: .exactName))

    let plan = CalendarReconciliation.constraintPlan(
      candidates: [proposed],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())

    #expect(plan.upserts.isEmpty)
    #expect(plan.localState.linkedConstraints.isEmpty)
  }

  @Test func existingConstraintSurvivesAStillAmbiguousMatch() throws {
    let event = observedEvent()
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let stop = ResolvedStop(
      entry: TripIdea(id: UUID(), tripID: tripID, ideaID: nil, inlineTitle: "Tax Advisor"),
      content: .freeform(title: "Tax Advisor", note: nil))

    let refreshed = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event, result: .proposed(stop, basis: .exactName))],
      tripID: tripID,
      calendarID: calendarID,
      localState: initial.localState)

    #expect(try #require(refreshed.upserts.first).id == initial.upserts.first?.id)
    #expect(refreshed.deletions.isEmpty)
    #expect(refreshed.localState.linkedConstraints.count == 1)
  }

  @Test func automaticStopLinkSupersedesExistingConstraint() throws {
    let event = observedEvent()
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let constraintID = try #require(initial.upserts.first?.id)
    let stopID = UUID()
    var linkedState = initial.localState
    linkedState.linkedStops = [CalendarLinkedStop(
      stopID: stopID,
      eventID: event.id,
      commitment: CalendarCommitment(event: event)!,
      observedAt: .distantPast,
      sourceExternalIdentifier: event.externalIdentifier)]
    let stop = ResolvedStop(
      entry: TripIdea(id: stopID, tripID: tripID, ideaID: nil, inlineTitle: "Tax Advisor"),
      content: .freeform(title: "Tax Advisor", note: nil))

    let linked = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event, result: .automatic(stop, basis: .exactName))],
      tripID: tripID,
      calendarID: calendarID,
      localState: linkedState)

    expectNoDifference(linked.deletions, [constraintID])
    #expect(linked.upserts.isEmpty)
    #expect(linked.localState.linkedConstraints.isEmpty)
  }

  @Test func confirmedDeletionRemovesOnlyCalendarOriginatedConstraint() throws {
    let event = observedEvent(identifier: "deleted-local-id")
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let constraintID = try #require(initial.upserts.first?.id)

    let deleted = CalendarReconciliation.constraintPlan(
      candidates: [],
      tripID: tripID,
      calendarID: calendarID,
      localState: initial.localState,
      deletedEventIDs: [event.id])

    expectNoDifference(deleted.deletions, [constraintID])
    #expect(deleted.localState.linkedConstraints.isEmpty)
  }

  @Test func movedOutsideConstraintRemovesRowButRetainsBinding() throws {
    let event = observedEvent(identifier: "moved-local-id")
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let constraintID = try #require(initial.upserts.first?.id)

    let moved = CalendarReconciliation.constraintPlan(
      candidates: [],
      tripID: tripID,
      calendarID: calendarID,
      localState: initial.localState,
      movedOutsideEventIDs: [event.id])

    expectNoDifference(moved.deletions, [constraintID])
    // The binding survives so a move back into the trip can heal it.
    #expect(moved.localState.linkedConstraints.count == 1)
  }

  @Test func constraintMovingBackIntoTripIsRecreatedWithSameIdentity() throws {
    let event = observedEvent(identifier: "moved-local-id")
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let constraintID = try #require(initial.upserts.first?.id)
    let moved = CalendarReconciliation.constraintPlan(
      candidates: [],
      tripID: tripID,
      calendarID: calendarID,
      localState: initial.localState,
      movedOutsideEventIDs: [event.id])

    let returned = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: moved.localState)

    expectNoDifference(returned.upserts.map(\.id), [constraintID])
    #expect(returned.deletions.isEmpty)
    #expect(returned.localState.linkedConstraints.count == 1)
  }

  @Test func anotherCalendarsDeletionEvidenceCannotRemoveConstraint() throws {
    let event = observedEvent(identifier: "deleted-local-id")
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(event)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState())

    let plan = CalendarReconciliation.constraintPlan(
      candidates: [],
      tripID: tripID,
      calendarID: "different-calendar",
      localState: initial.localState,
      deletedEventIDs: [event.id])

    #expect(plan.deletions.isEmpty)
    #expect(plan.localState.linkedConstraints.count == 1)
  }

  @Test func deletionEvidenceNeverRemovesGalavantOriginatedStop() {
    let event = observedEvent(identifier: "linked-stop-event")
    let commitment = CalendarCommitment(event: event)!
    let localState = CalendarReconciliationLocalState(
      linkedStops: [CalendarLinkedStop(
        stopID: UUID(),
        eventID: event.id,
        commitment: commitment,
        observedAt: .distantPast,
        sourceExternalIdentifier: event.externalIdentifier)])

    let plan = CalendarReconciliation.constraintPlan(
      candidates: [],
      tripID: tripID,
      calendarID: calendarID,
      localState: localState,
      deletedEventIDs: [event.id])

    #expect(plan.deletions.isEmpty)
    #expect(plan.localState.linkedStops.count == 1)
  }

  @Test func recurringOccurrencesHaveDistinctConstraintIdentity() throws {
    let firstAnchor = date(day: 12, hour: 10)
    let secondAnchor = date(day: 19, hour: 10)
    let first = observedEvent(
      identifier: "occurrence-a",
      recurrence: CalendarEventRecurrence(
        originalOccurrence: .absolute(firstAnchor), isDetached: false))
    let second = observedEvent(
      identifier: "occurrence-b",
      recurrence: CalendarEventRecurrence(
        originalOccurrence: .absolute(secondAnchor), isDetached: false))

    let firstPlan = CalendarReconciliation.constraintPlan(
      candidates: [candidate(first)], tripID: tripID, calendarID: calendarID,
      localState: CalendarReconciliationLocalState())
    let secondPlan = CalendarReconciliation.constraintPlan(
      candidates: [candidate(second)], tripID: tripID, calendarID: calendarID,
      localState: CalendarReconciliationLocalState())

    #expect(try #require(firstPlan.upserts.first).id != secondPlan.upserts.first?.id)
  }

  @Test func recurringOccurrenceRekeyedAllDayToTimedSupersedesStaleConstraint() throws {
    let day2 = CalendarCivilDate(year: 2026, month: 8, day: 12)!
    let allDayOccurrence = CalendarObservedEvent(
      id: "allday-local",
      eventIdentifier: "allday-local",
      externalIdentifier: "series-1",
      title: "Morning Check-in",
      temporal: .allDay(
        start: day2, endExclusive: CalendarCivilDate(year: 2026, month: 8, day: 13)!),
      recurrence: CalendarEventRecurrence(
        originalOccurrence: .allDay(day2), isDetached: false),
      calendarTitle: "Family")
    let initial = CalendarReconciliation.constraintPlan(
      candidates: [candidate(allDayOccurrence)],
      tripID: tripID,
      calendarID: calendarID,
      localState: CalendarReconciliationLocalState(),
      regionTimeZone: timeZone)
    let allDayID = try #require(initial.upserts.first?.id)

    // Assigning a time to the recurring series re-keys the occurrence anchor
    // (all-day → absolute), so the same slot reappears under a new identity.
    let timedStart = date(day: 12, hour: 8)
    let timedOccurrence = CalendarObservedEvent(
      id: "timed-local",
      eventIdentifier: "timed-local",
      externalIdentifier: "series-1",
      title: "Morning Check-in",
      temporal: .absolute(
        start: timedStart, end: timedStart.addingTimeInterval(3600), timeZone: timeZone),
      availability: .busy,
      recurrence: CalendarEventRecurrence(
        originalOccurrence: .absolute(timedStart), isDetached: false),
      calendarTitle: "Family")
    let rekeyed = CalendarReconciliation.constraintPlan(
      candidates: [candidate(timedOccurrence)],
      tripID: tripID,
      calendarID: calendarID,
      localState: initial.localState,
      regionTimeZone: timeZone)

    let timedID = try #require(rekeyed.upserts.first?.id)
    #expect(timedID != allDayID)
    expectNoDifference(rekeyed.deletions, [allDayID])
    #expect(rekeyed.localState.linkedConstraints.count == 1)
  }

  @Test func constraintUpsertAndProvenanceDeletionRoundTrip() async throws {
    let trip = try await database.write { db in
      try Trip.create(name: "Rome", in: db)
    }
    let event = observedEvent()
    let constraint = try #require(CalendarTripConstraint(
      tripID: trip.id,
      event: event,
      projection: .day(2, timeZone: timeZone)))
    let modifiedConstraint = {
      var value = constraint
      value.title = "Call Accountant"
      return value
    }()
    let constraintID = constraint.id

    let count = try await database.write { db -> Int in
      try CalendarTripConstraint.upsert(constraint, in: db)
      try CalendarTripConstraint.upsert(modifiedConstraint, in: db)
      return try CalendarTripConstraint.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    let saved = try await database.read { db in
      try CalendarTripConstraint.find(constraintID).fetchOne(db)
    }

    #expect(count == 1)
    #expect(saved?.title == "Call Accountant")

    let remaining = try await database.write { db -> Int in
      try CalendarTripConstraint.remove(id: constraintID, in: db)
      return try CalendarTripConstraint.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    #expect(remaining == 0)
  }

  @Test func constraintsWeaveIntoTimelineByCivilTime() throws {
    let idea = Idea(id: UUID(), name: "Lunch")
    var stop = TripIdea(
      id: UUID(), tripID: tripID, ideaID: idea.id, status: .scheduled)
    stop.apply(.timed(2, start: "12:00", end: nil))
    let allDayEvent = CalendarObservedEvent(
      id: "all-day",
      eventIdentifier: "all-day",
      externalIdentifier: "all-day-server",
      title: "Tax filing deadline",
      temporal: .allDay(
        start: CalendarCivilDate(year: 2026, month: 8, day: 12)!,
        endExclusive: CalendarCivilDate(year: 2026, month: 8, day: 13)!),
      calendarTitle: "Family")
    let allDay = try #require(CalendarTripConstraint(
      tripID: tripID,
      event: allDayEvent,
      projection: .day(2, timeZone: nil)))
    let timed = try #require(CalendarTripConstraint(
      tripID: tripID,
      event: observedEvent(hour: 10),
      projection: .day(2, timeZone: timeZone)))
    let tripPlan = TripPlan(
      entries: [stop],
      ideasByID: [idea.id: idea],
      lengthInDays: 3,
      calendarConstraints: [timed, allDay])

    let items = tripPlan.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:])

    expectNoDifference(items.map(\.id), [
      "calendarConstraint-\(allDay.id)",
      "calendarConstraint-\(timed.id)",
      "stop-\(stop.id)",
    ])
  }

  @Test func legacyLocalStateDecodesWithNoConstraintBindings() throws {
    struct LegacyState: Codable {
      var linkedStops: [CalendarLinkedStop] = []
      var history: [CalendarReconciliationHistoryEntry] = []
    }

    let data = try JSONEncoder().encode(LegacyState())
    let state = try JSONDecoder().decode(CalendarReconciliationLocalState.self, from: data)

    expectNoDifference(state, CalendarReconciliationLocalState())
  }

  private func candidate(
    _ event: CalendarObservedEvent,
    result: CalendarReconciliationResult = .unmatched
  ) -> CalendarReconciliationCandidate {
    CalendarReconciliationCandidate(
      input: CalendarIngestedEvent(event: event, itineraryTimeZone: timeZone),
      result: result,
      projection: .day(2, timeZone: timeZone),
      temporalContext: CalendarTripTemporalContext(
        tripStart: CalendarCivilDate(year: 2026, month: 8, day: 11)!,
        dayCount: 3))
  }

  private func observedEvent(
    title: String = "Call Tax Advisor",
    identifier: String = "local-event",
    hour: Int = 10,
    recurrence: CalendarEventRecurrence? = nil
  ) -> CalendarObservedEvent {
    let start = date(day: 12, hour: hour)
    return CalendarObservedEvent(
      id: identifier,
      eventIdentifier: identifier,
      externalIdentifier: "server-event",
      title: title,
      temporal: .absolute(
        start: start,
        end: start.addingTimeInterval(60 * 60),
        timeZone: timeZone),
      availability: .busy,
      recurrence: recurrence,
      calendarTitle: "Family")
  }

  private func date(day: Int, hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(
      year: 2026, month: 8, day: day, hour: hour))!
  }
}
