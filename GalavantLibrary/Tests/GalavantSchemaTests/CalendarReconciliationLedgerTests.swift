@testable import GalavantSchema
import Dependencies
import Foundation
import GRDB
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct CalendarReconciliationLedgerTests {
  @Dependency(\.defaultDatabase) private var database

  @Test func sharedCalendarRevisionMakesTheSameOutcomeIDOnBothDevices() {
    let first = CalendarObservedEvent(
      id: "device-a-local-id",
      eventIdentifier: "device-a-local-id",
      externalIdentifier: "server-calendar-item",
      lastModifiedDate: .distantFuture,
      title: "French Laundry",
      startDate: .distantPast,
      endDate: .distantPast.addingTimeInterval(60 * 60),
      isAllDay: false,
      calendarTitle: "Family")
    let second = CalendarObservedEvent(
      id: "device-b-local-id",
      eventIdentifier: "device-b-local-id",
      externalIdentifier: "server-calendar-item",
      lastModifiedDate: .distantFuture,
      title: "French Laundry",
      startDate: .distantPast,
      endDate: .distantPast.addingTimeInterval(60 * 60),
      isAllDay: false,
      calendarTitle: "Family")
    let tripID = UUID()
    let stopID = UUID()
    let commitment = CalendarCommitment.timed(
      start: .distantPast, end: .distantPast.addingTimeInterval(60 * 60))
    let firstHistory = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .linked, stopID: stopID, eventID: first.id,
      eventTitle: first.title, current: commitment,
      sourceFingerprint: CalendarReconciliationFingerprint.source(for: first), appliedAt: .now)
    let secondHistory = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .linked, stopID: stopID, eventID: second.id,
      eventTitle: second.title, current: commitment,
      sourceFingerprint: CalendarReconciliationFingerprint.source(for: second), appliedAt: .distantFuture)

    let firstEntry = CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: firstHistory)
    let secondEntry = CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: secondHistory)

    #expect(firstEntry?.id == secondEntry?.id)
    #expect(firstEntry?.sourceFingerprint == secondEntry?.sourceFingerprint)
  }

  @Test func recordsOnceWhenARefreshRepeatsTheSameOutcome() async throws {
    let tripID = try await database.write { db in
      try Trip.create(name: "Copenhagen", in: db).id
    }
    let history = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .updated, stopID: UUID(), eventID: "device-only-event-id",
      eventTitle: "Noma", previous: .allDay(date: .distantPast),
      current: .allDay(date: .distantFuture), sourceFingerprint: "source-revision", appliedAt: .now)
    let entry = try #require(CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: history))

    let count = try await database.write { db -> Int in
      try CalendarReconciliationLedgerEntry.record(entry, in: db)
      try CalendarReconciliationLedgerEntry.record(entry, in: db)
      return try CalendarReconciliationLedgerEntry.where { $0.tripID.eq(tripID) }.fetchCount(db)
    }

    #expect(count == 1)
  }

  @Test func legacyLocalHistoryDoesNotInventSharedIdentity() {
    let history = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .linked, stopID: UUID(), eventID: "old-local-id",
      eventTitle: "Legacy", current: .allDay(date: .distantPast), appliedAt: .distantPast)

    #expect(CalendarReconciliationLedgerEntry(tripID: UUID(), historyEntry: history) == nil)
  }
}
