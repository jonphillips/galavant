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

  @Test func divergentLocalTransitionsMakeOneSharedOutcomeID() throws {
    let tripID = UUID()
    let stopID = UUID()
    let current = CalendarCommitment.allDay(date: .distantFuture)
    let sourceFingerprint = try #require(CalendarReconciliationFingerprint.source(for: CalendarObservedEvent(
      id: "device-local-id",
      eventIdentifier: "device-local-id",
      externalIdentifier: "server-calendar-item",
      title: "Noma",
      startDate: .distantFuture,
      endDate: .distantFuture.addingTimeInterval(60 * 60),
      isAllDay: true,
      calendarTitle: "Family")))
    let updated = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .updated, stopID: stopID, eventID: "device-a-event-id",
      eventTitle: "Noma", previous: .allDay(date: .distantPast), current: current,
      sourceFingerprint: sourceFingerprint, appliedAt: .now)
    let newlyLinked = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .linked, stopID: stopID, eventID: "device-b-event-id",
      eventTitle: "Noma", current: current,
      sourceFingerprint: sourceFingerprint, appliedAt: .distantFuture)

    let updatedEntry = try #require(CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: updated))
    let linkedEntry = try #require(CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: newlyLinked))

    #expect(updatedEntry.id == linkedEntry.id)
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

  @Test func eventWithoutServerIdentityStaysLocal() {
    let event = CalendarObservedEvent(
      id: "device-local-id",
      eventIdentifier: "device-local-id",
      title: "Local Event",
      startDate: .distantPast,
      endDate: .distantPast.addingTimeInterval(60 * 60),
      isAllDay: false,
      calendarTitle: "Family")
    let history = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .linked, stopID: UUID(), eventID: event.id,
      eventTitle: event.title, current: .timed(start: event.startDate, end: event.endDate),
      sourceFingerprint: CalendarReconciliationFingerprint.source(for: event), appliedAt: .now)

    #expect(CalendarReconciliationLedgerEntry(tripID: UUID(), historyEntry: history) == nil)
  }
}
