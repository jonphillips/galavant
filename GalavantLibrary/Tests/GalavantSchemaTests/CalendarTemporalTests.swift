@testable import GalavantSchema
import CustomDump
import Foundation
import Testing

@Suite struct CalendarTemporalTests {
  private let newYork = TimeZone(identifier: "America/New_York")!
  private let rome = TimeZone(identifier: "Europe/Rome")!

  private func calendar(in timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }

  private func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
    in timeZone: TimeZone
  ) -> Date {
    calendar(in: timeZone).date(from: DateComponents(
      year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func civilDate(_ year: Int, _ month: Int, _ day: Int) -> CalendarCivilDate {
    CalendarCivilDate(year: year, month: month, day: day)!
  }

  private func civilDateTime(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
  ) -> CalendarCivilDateTime {
    CalendarCivilDateTime(
      date: civilDate(year, month, day), hour: hour, minute: minute)!
  }

  @Test func zonedEventKeepsItsInstantDisplayZoneAndDestinationDayProjection() throws {
    let start = date(2026, 8, 11, 23, 30, in: newYork)
    let end = date(2026, 8, 12, 0, 30, in: newYork)
    let commitment = try #require(CalendarCommitment(
      temporal: .absolute(start: start, end: end, timeZone: newYork),
      availability: .busy))

    expectNoDifference(commitment.temporal.nativeStartDate, civilDate(2026, 8, 11))
    expectNoDifference(commitment.temporal.startDate(in: rome), civilDate(2026, 8, 12))
    expectNoDifference(
      commitment.schedule(on: 3),
      .timed(3, start: "23:30", end: "00:30"))
    expectNoDifference(
      commitment.hardOccupiedInterval(interpretingFloatingIn: rome),
      DateInterval(start: start, end: end))
  }

  @Test func perDayZoneResolverUsesOverrideThenRegionThenCentroid() throws {
    let eastern = try #require(TimeZone(identifier: "America/New_York"))
    let cet = try #require(TimeZone(identifier: "Europe/Paris"))
    let rome = try #require(TimeZone(identifier: "Europe/Rome"))

    #expect(CalendarTripTimeZoneResolver.resolve(
      dayOverride: eastern, dayRegion: cet, tripCentroid: rome) == eastern)
    #expect(CalendarTripTimeZoneResolver.resolve(
      dayOverride: nil, dayRegion: cet, tripCentroid: rome) == cet)
    #expect(CalendarTripTimeZoneResolver.resolve(
      dayOverride: nil, dayRegion: nil, tripCentroid: rome) == rome)
  }

  @Test func assignmentUsesFallbackWhileResolvedDayCarriesDisplayZone() throws {
    let eastern = try #require(TimeZone(identifier: "America/New_York"))
    let cet = try #require(TimeZone(identifier: "Europe/Paris"))
    let tripStart = civilDate(2026, 8, 12)
    let start = date(2026, 8, 11, 22, 0, in: eastern)
    let context = try #require(CalendarTripTemporalContext(
      tripStart: tripStart, dayCount: 3,
      assignmentTimeZone: cet, dayTimeZones: [1: eastern]))

    expectNoDifference(
      context.project(
        .absolute(start: start, end: start.addingTimeInterval(3600), timeZone: eastern),
        absoluteTimeZone: eastern),
      .day(1, timeZone: cet))
  }

  @Test func floatingEventKeepsCivilTimeAcrossDeviceZones() throws {
    let start = civilDateTime(2026, 8, 12, 10, 0)
    let end = civilDateTime(2026, 8, 12, 11, 0)
    let commitment = try #require(CalendarCommitment(
      temporal: .floating(start: start, end: end),
      availability: .busy))

    expectNoDifference(
      commitment.schedule(on: 2),
      .timed(2, start: "10:00", end: "11:00"))
    #expect(commitment.pinnedDate == nil)
    #expect(
      commitment.hardOccupiedInterval(interpretingFloatingIn: newYork)?.start
        != commitment.hardOccupiedInterval(interpretingFloatingIn: rome)?.start)
  }

  @Test func allDayIsCivilContextRatherThanTwentyFourHoursBusy() throws {
    let commitment = try #require(CalendarCommitment(
      temporal: .allDay(
        start: civilDate(2026, 8, 12),
        endExclusive: civilDate(2026, 8, 14)),
      availability: .busy))

    #expect(commitment.occupancy == .dayContext)
    #expect(commitment.hardOccupiedInterval(interpretingFloatingIn: rome) == nil)
    expectNoDifference(commitment.schedule(on: 4), .day(4))
  }

  @Test func freeTentativeAndUnavailableRemainDistinct() throws {
    let temporal = CalendarEventTime.absolute(
      start: date(2026, 8, 12, 10, 0, in: rome),
      end: date(2026, 8, 12, 11, 0, in: rome),
      timeZone: rome)
    let free = try #require(CalendarCommitment(temporal: temporal, availability: .free))
    let tentative = try #require(CalendarCommitment(temporal: temporal, availability: .tentative))
    let unavailable = try #require(CalendarCommitment(temporal: temporal, availability: .unavailable))

    #expect(free.occupancy == .free)
    #expect(free.hardOccupiedInterval(interpretingFloatingIn: rome) == nil)
    #expect(tentative.occupancy == .tentative)
    #expect(tentative.hardOccupiedInterval(interpretingFloatingIn: rome) == nil)
    #expect(unavailable.occupancy == .unavailable)
    #expect(unavailable.hardOccupiedInterval(interpretingFloatingIn: rome) != nil)
  }

  @Test func tripScopeUsesEventSemanticsInsteadOfTheDeviceZone() throws {
    let scope = try #require(CalendarTripScope(
      start: civilDate(2026, 8, 12), dayCount: 2))
    let allDay = CalendarEventTime.allDay(
      start: civilDate(2026, 8, 11),
      endExclusive: civilDate(2026, 8, 13))
    let floating = CalendarEventTime.floating(
      start: civilDateTime(2026, 8, 13, 23, 0),
      end: civilDateTime(2026, 8, 14, 1, 0))
    let zoned = CalendarEventTime.absolute(
      start: date(2026, 8, 11, 23, 30, in: newYork),
      end: date(2026, 8, 12, 0, 30, in: newYork),
      timeZone: newYork)

    #expect(scope.overlaps(allDay, absoluteTimeZone: nil) == true)
    #expect(scope.overlaps(floating, absoluteTimeZone: nil) == true)
    #expect(scope.overlaps(zoned, absoluteTimeZone: rome) == true)
  }

  @Test func absoluteEventUsesItineraryZoneForScopeAndDayProjection() throws {
    let tripStart = date(2026, 8, 12, 0, 0, in: rome)
    let context = try #require(CalendarTripTemporalContext(
      tripStart: CalendarCivilDate(tripStart, calendar: calendar(in: rome)), dayCount: 3))
    let scope = try #require(CalendarTripScope(
      start: civilDate(2026, 8, 12), dayCount: 3))
    let event = CalendarEventTime.absolute(
      start: date(2026, 8, 11, 22, 0, in: newYork),
      end: date(2026, 8, 11, 23, 0, in: newYork),
      timeZone: newYork)

    expectNoDifference(context.project(event, absoluteTimeZone: rome), .day(1, timeZone: rome))
    #expect(scope.overlaps(event, absoluteTimeZone: rome) == true)
    #expect(scope.overlaps(event, absoluteTimeZone: newYork) == false)
    #expect(scope.overlaps(event, absoluteTimeZone: nil) == nil)
  }

  @Test func tripStartCivilDayIsSharedByAllDayAndAbsoluteProjection() throws {
    // A trip chosen as August 12 on a Rome device persists as August 11 in UTC.
    // Its civil day must nevertheless remain August 12 for every event shape.
    let storedTripStart = date(2026, 8, 12, 0, 0, in: rome)
    let scope = try #require(CalendarTripScope(
      start: CalendarCivilDate(storedTripStart, calendar: calendar(in: rome)), dayCount: 3))
    let context = CalendarTripTemporalContext(scope: scope)
    let firstDayAllDay = CalendarEventTime.allDay(
      start: civilDate(2026, 8, 12), endExclusive: civilDate(2026, 8, 13))
    let lastDayAllDay = CalendarEventTime.allDay(
      start: civilDate(2026, 8, 14), endExclusive: civilDate(2026, 8, 15))
    let firstDayAbsolute = CalendarEventTime.absolute(
      start: date(2026, 8, 12, 10, 0, in: rome),
      end: date(2026, 8, 12, 11, 0, in: rome),
      timeZone: rome)

    #expect(scope.overlaps(firstDayAllDay, absoluteTimeZone: nil) == true)
    #expect(scope.overlaps(lastDayAllDay, absoluteTimeZone: nil) == true)
    expectNoDifference(context.project(firstDayAllDay, absoluteTimeZone: nil), .day(1, timeZone: nil))
    expectNoDifference(context.project(lastDayAllDay, absoluteTimeZone: nil), .day(3, timeZone: nil))
    expectNoDifference(context.project(firstDayAbsolute, absoluteTimeZone: rome), .day(1, timeZone: rome))
  }

  @Test func recurrenceFingerprintIdentifiesOneOccurrenceNotTheSeries() throws {
    let revision = date(2026, 7, 1, 9, 0, in: newYork)
    let firstStart = date(2026, 8, 11, 19, 0, in: newYork)
    let secondStart = date(2026, 8, 18, 19, 0, in: newYork)
    let first = recurringEvent(start: firstStart, originalOccurrence: firstStart, revision: revision)
    let second = recurringEvent(start: secondStart, originalOccurrence: secondStart, revision: revision)

    let firstFingerprint = try #require(CalendarReconciliationFingerprint.source(for: first))
    let secondFingerprint = try #require(CalendarReconciliationFingerprint.source(for: second))
    #expect(firstFingerprint != secondFingerprint)
  }

  @Test func detachedOccurrenceKeepsIdentityAfterItsStartMoves() throws {
    let revision = date(2026, 7, 1, 9, 0, in: newYork)
    let original = date(2026, 8, 11, 19, 0, in: newYork)
    let first = recurringEvent(start: original, originalOccurrence: original, revision: revision)
    let moved = recurringEvent(
      start: date(2026, 8, 12, 20, 0, in: newYork),
      originalOccurrence: original,
      revision: revision,
      isDetached: true)

    expectNoDifference(
      CalendarReconciliationFingerprint.source(for: first),
      CalendarReconciliationFingerprint.source(for: moved))
  }

  @Test func ledgerRoundTripsCompleteTemporalSnapshot() throws {
    let commitment = try #require(CalendarCommitment(
      temporal: .floating(
        start: civilDateTime(2026, 8, 12, 10, 0),
        end: civilDateTime(2026, 8, 12, 11, 0)),
      availability: .tentative))
    let history = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .linked, stopID: UUID(), eventID: "local-event",
      eventTitle: "Lunch", current: commitment, sourceFingerprint: "source", appliedAt: .now)
    let entry = try #require(CalendarReconciliationLedgerEntry(
      tripID: UUID(), historyEntry: history))

    #expect(entry.currentSnapshot != nil)
    expectNoDifference(entry.current, commitment)
  }

  @Test func moveOutsideTripIsNotPromotedToTheSharedLedger() throws {
    // A move-outside applied nothing to the shared itinerary; it stays device-local.
    let commitment = try #require(CalendarCommitment(
      temporal: .absolute(
        start: date(2026, 11, 5, 19, 0, in: rome),
        end: date(2026, 11, 5, 22, 0, in: rome),
        timeZone: rome),
      availability: .busy))
    let moved = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .movedOutsideTrip, stopID: UUID(), eventID: "local-event",
      eventTitle: "Geranium", current: commitment, sourceFingerprint: "source", appliedAt: .now)

    #expect(CalendarReconciliationLedgerEntry(tripID: UUID(), historyEntry: moved) == nil)
  }

  @Test func commitmentDecodesSliceTwoHistory() throws {
    enum LegacyCalendarCommitment: Codable {
      case allDay(date: Date)
      case timed(start: Date, end: Date)
    }
    let start = date(2026, 8, 12, 10, 0, in: newYork)
    let end = date(2026, 8, 12, 11, 0, in: newYork)
    let data = try JSONEncoder().encode(LegacyCalendarCommitment.timed(start: start, end: end))

    let commitment = try JSONDecoder().decode(CalendarCommitment.self, from: data)

    expectNoDifference(
      commitment,
      .timed(start: start, end: end, timeZone: .current))
  }

  @Test func malformedTemporalRangeDoesNotBecomeACommitment() {
    let instant = date(2026, 8, 12, 10, 0, in: rome)
    #expect(CalendarCommitment(
      temporal: .absolute(start: instant, end: instant, timeZone: rome),
      availability: .busy) == nil)
  }

  @Test func nonexistentFloatingCivilTimeRequiresReconciliation() {
    let missing = civilDateTime(2026, 3, 8, 2, 30)

    #expect(missing.instant(in: newYork) == nil)
  }

  private func recurringEvent(
    start: Date,
    originalOccurrence: Date,
    revision: Date,
    isDetached: Bool = false
  ) -> CalendarObservedEvent {
    CalendarObservedEvent(
      id: UUID().uuidString,
      eventIdentifier: UUID().uuidString,
      externalIdentifier: "server-series",
      lastModifiedDate: revision,
      title: "Weekly dinner",
      temporal: .absolute(
        start: start,
        end: start.addingTimeInterval(60 * 60),
        timeZone: newYork),
      availability: .busy,
      recurrence: CalendarEventRecurrence(
        originalOccurrence: .absolute(originalOccurrence),
        isDetached: isDetached),
      calendarTitle: "Family")
  }
}
