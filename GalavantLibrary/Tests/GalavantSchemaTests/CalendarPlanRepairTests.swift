@testable import GalavantSchema
import Dependencies
import Foundation
import GRDB
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct CalendarPlanRepairTests {
  @Dependency(\.defaultDatabase) private var database

  @Test func dayMoveCreatesOneDeterministicSharedRepair() throws {
    let tripID = UUID()
    let stopID = UUID()
    let commitment = CalendarCommitment.timed(
      start: .distantFuture,
      end: .distantFuture.addingTimeInterval(60 * 60))
    let application = CalendarReconciliationApplication(
      stopID: stopID, commitment: commitment, dayNumber: 3, kind: .updated,
      sourceFingerprint: "calendar-revision", eventTitle: "French Laundry")

    let first = CalendarReconciliation.planRepairs(
      applications: [application], previousDayNumbers: [stopID: 2], history: [], tripID: tripID)
    let second = CalendarReconciliation.planRepairs(
      applications: [application], previousDayNumbers: [stopID: 2], history: [], tripID: tripID)

    #expect(first.count == 1)
    #expect(first.first?.kind == .movedDay)
    #expect(first.first?.id == second.first?.id)
  }

  @Test func clockOnlyUpdateDoesNotAskForPlanRepair() {
    let stopID = UUID()
    let application = CalendarReconciliationApplication(
      stopID: stopID,
      commitment: .timed(start: .distantFuture, end: .distantFuture.addingTimeInterval(60 * 60)),
      dayNumber: 2, kind: .updated, sourceFingerprint: "calendar-revision", eventTitle: "Noma")

    let repairs = CalendarReconciliation.planRepairs(
      applications: [application], previousDayNumbers: [stopID: 2], history: [], tripID: UUID())

    #expect(repairs.isEmpty)
  }

  @Test func movedOutsideLinkedStopBecomesSharedRepair() {
    let stopID = UUID()
    let history = CalendarReconciliationHistoryEntry(
      id: UUID(), kind: .movedOutsideTrip, stopID: stopID, eventID: "device-local",
      eventTitle: "French Laundry", previous: .allDay(date: .distantPast),
      current: .allDay(date: .distantFuture), sourceFingerprint: "calendar-revision", appliedAt: .now)

    let repairs = CalendarReconciliation.planRepairs(
      applications: [], previousDayNumbers: [:], history: [history], tripID: UUID())

    #expect(repairs.first?.kind == .movedOutsideTrip)
    #expect(repairs.first?.stopID == stopID)
  }

  @Test func recordingThenResolvingKeepsTheRepairAsSharedHistory() async throws {
    let tripID = try await database.write { db in try Trip.create(name: "Rome", in: db).id }
    let repair = try #require(CalendarPlanRepair(
      tripID: tripID, sourceFingerprint: "calendar-revision", stopID: UUID(),
      title: "Museum", kind: .movedDay,
      commitment: .timed(start: .distantFuture, end: .distantFuture.addingTimeInterval(60 * 60))))

    try await database.write { db in
      try CalendarPlanRepair.record(repair, in: db)
      try CalendarPlanRepair.record(repair, in: db)
      try CalendarPlanRepair.resolve(id: repair.id, at: .distantFuture, in: db)
    }
    let saved = try await database.read { db in try CalendarPlanRepair.find(repair.id).fetchOne(db) }

    #expect(saved?.isResolved == true)
    #expect(saved?.resolvedAt == .distantFuture)
  }

  @Test func anchorAssessmentSuggestsOneStartOrSurfacesTheDisagreement() {
    let first = TripStartAnchor(
      stopID: UUID(), stopName: "French Laundry", dayNumber: 3,
      commitmentDate: CalendarCivilDate(year: 2026, month: 9, day: 15)!)
    let agreeing = TripStartAnchor(
      stopID: UUID(), stopName: "Museum", dayNumber: 1,
      commitmentDate: CalendarCivilDate(year: 2026, month: 9, day: 13)!)
    let conflicting = TripStartAnchor(
      stopID: UUID(), stopName: "Flight", dayNumber: 1,
      commitmentDate: CalendarCivilDate(year: 2026, month: 9, day: 14)!)

    let consistent = StartDaySolver.assess(anchors: [first, agreeing])
    #expect(consistent.proposedStart == CalendarCivilDate(year: 2026, month: 9, day: 13))
    #expect(consistent.isConsistent)

    let inconsistent = StartDaySolver.assess(anchors: [first, conflicting])
    #expect(!inconsistent.isConsistent)
    #expect(inconsistent.conflictingAnchors == [conflicting])
  }

  @Test func tripPastBoundaryStartsAfterItsFinalCivilDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13))!
    let trip = Trip(id: UUID(), name: "Rome", startDate: start, lengthInDays: 3)
    let finalDay = calendar.date(byAdding: .day, value: 2, to: start)!
    let firstMomentAfter = calendar.date(byAdding: .day, value: 3, to: start)!

    #expect(!trip.isPast(at: finalDay, calendar: calendar))
    #expect(trip.isPast(at: firstMomentAfter, calendar: calendar))
  }

  @Test func finalReconciliationFreezesOnceWithoutTouchingStops() async throws {
    let trip = try await database.write { db in
      try Trip.create(name: "Rome", in: db)
    }
    let stop = TripIdea.freeform(id: UUID(), tripID: trip.id, title: "Train")
    try await database.write { db in
      try TripIdea.insert { TripIdea.Draft(stop) }.execute(db)
      try Trip.completeCalendarReconciliation(tripID: trip.id, frozenAt: .distantFuture, in: db)
      // A second successful observation preserves the first frozen boundary.
      try Trip.completeCalendarReconciliation(tripID: trip.id, frozenAt: .distantPast, in: db)
    }
    let saved = try await database.read { db in
      (
        try Trip.find(trip.id).fetchOne(db),
        try TripIdea.find(stop.id).fetchOne(db)
      )
    }

    #expect(saved.0?.calendarReconciliationFrozenAt == .distantFuture)
    // Freezing ends Calendar authority only; it must not roll stops into visited.
    #expect(saved.1?.status == .scheduled)
  }
}
