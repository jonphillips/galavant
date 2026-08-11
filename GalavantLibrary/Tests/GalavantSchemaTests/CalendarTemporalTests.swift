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

    #expect(scope.overlaps(allDay))
    #expect(scope.overlaps(floating))
    #expect(scope.overlaps(zoned))
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
