import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct VisitedRollupTests {
  @Dependency(\.defaultDatabase) var database

  @Test func plannerSelectsOnlyEligibleIdeas() {
    let calendar = utcCalendar
    let start = Date(timeIntervalSince1970: 1_000)
    let now = calendar.date(byAdding: .day, value: 2, to: start)!
    let trip = Trip(id: UUID(), certaintyStage: .dated, startDate: start, lengthInDays: 1)
    let ideaIDs = (0..<7).map { _ in UUID() }
    let ring = UUID()
    let stops = [
      stop(ideaIDs[0], day: 1), // Pending scheduled stop counts.
      stop(ideaIDs[1], day: 1, skippedAt: now),
      stop(ideaIDs[2], day: nil), // Scheduled but not placed on a day.
      stop(nil, day: 1), // Freeform.
      stop(ideaIDs[3], day: 1, group: ring),
      stop(ideaIDs[4], day: 1, group: ring, completedAt: now),
      stop(ideaIDs[5], day: 1, status: .declined),
    ]

    #expect(VisitedRollup.ideaIDs(for: trip, tripIdeas: stops, now: now, calendar: calendar)
      == [ideaIDs[0], ideaIDs[4]])
  }

  @Test func plannerUsesTripPastBoundaryAndMarker() {
    let calendar = utcCalendar
    let start = Date(timeIntervalSince1970: 1_000)
    let trip = Trip(id: UUID(), certaintyStage: .dated, startDate: start, lengthInDays: 1)
    let stop = stop(UUID(), day: 1)
    let boundary = calendar.date(byAdding: .day, value: 1, to: start)!

    #expect(VisitedRollup.ideaIDs(
      for: trip, tripIdeas: [stop], now: boundary.addingTimeInterval(-1), calendar: calendar).isEmpty)
    #expect(VisitedRollup.ideaIDs(
      for: Trip(id: UUID()), tripIdeas: [stop], now: boundary, calendar: calendar).isEmpty)
    var marked = trip
    marked.visitedRolledUpAt = boundary
    #expect(VisitedRollup.ideaIDs(
      for: marked, tripIdeas: [stop], now: boundary, calendar: calendar).isEmpty)
    #expect(VisitedRollup.ideaIDs(
      for: trip, tripIdeas: [stop], now: boundary, calendar: calendar) == [stop.ideaID!])
  }

  @Test func operationIsAtomicAndDoesNotChangeStops() async throws {
    let calendar = utcCalendar
    let start = Date(timeIntervalSince1970: 1_000)
    let now = calendar.date(byAdding: .day, value: 2, to: start)!
    let (tripID, ideaID, stopID) = try await database.write { db -> (UUID, UUID, UUID) in
      let trip = Trip(id: UUID(), name: "Past", certaintyStage: .dated, startDate: start, lengthInDays: 1)
      let idea = Idea(id: UUID(), name: "Place")
      let stop = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: idea.id,
        status: .scheduled, dayNumber: 1, completedAt: now)
      try Trip.insert { Trip.Draft(trip) }.execute(db)
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      try TripIdea.insert { TripIdea.Draft(stop) }.execute(db)
      return (trip.id, idea.id, stop.id)
    }
    let beforePlan = try await database.read { db -> TripPlan in
      let idea = try Idea.find(ideaID).fetchOne(db)!
      let stop = try TripIdea.find(stopID).fetchOne(db)!
      return TripPlan(entries: [stop], ideasByID: [ideaID: idea], lengthInDays: 1)
    }
    let beforeItinerary = beforePlan.itinerary.map { $0.stops.map(\.entry) }

    try await database.write { db in
      try Trip.rollUpVisited(tripID: tripID, now: now, calendar: calendar, in: db)
    }
    let first = try await database.read { db in
      (
        try Idea.find(ideaID).fetchOne(db)!,
        try Trip.find(tripID).fetchOne(db)!,
        try TripIdea.find(stopID).fetchOne(db)!
      )
    }
    let afterPlan = TripPlan(entries: [first.2], ideasByID: [ideaID: first.0], lengthInDays: 1)
    #expect(first.0.visited)
    #expect(first.1.visitedRolledUpAt == now)
    #expect(first.2.status == .scheduled)
    #expect(first.2.completedAt == now)
    #expect(first.2.skippedAt == nil)
    #expect(afterPlan.itinerary.map { $0.stops.map(\.entry) } == beforeItinerary)

    try await database.write { db in
      try Idea.find(ideaID).update { $0.visited = #bind(false) }.execute(db)
      try Trip.rollUpVisited(tripID: tripID, now: now, calendar: calendar, in: db)
    }
    let remainsCleared = try await database.read { db in
      try Idea.find(ideaID).fetchOne(db)!.visited
    }
    #expect(!remainsCleared)
  }

  @Test func existingTripReadsNilMarker() async throws {
    let tripID = try await database.write { db -> UUID in
      let id = UUID()
      try Trip.insert { Trip.Draft(Trip(id: id)) }.execute(db)
      return id
    }
    let marker = try await database.read { db in
      try Trip.find(tripID).fetchOne(db)?.visitedRolledUpAt
    }
    #expect(marker == nil)
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func stop(
    _ ideaID: UUID?,
    day: Int?,
    status: TripIdeaStatus = .scheduled,
    group: UUID? = nil,
    completedAt: Date? = nil,
    skippedAt: Date? = nil
  ) -> TripIdea {
    TripIdea(
      id: UUID(), tripID: UUID(), ideaID: ideaID, status: status,
      alternativeGroupID: group, dayNumber: day,
      completedAt: completedAt, skippedAt: skippedAt)
  }
}
