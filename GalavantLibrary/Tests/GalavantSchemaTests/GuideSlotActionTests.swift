import Dependencies
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct GuideSlotActionTests {
  @Dependency(\.defaultDatabase) var database

  @Test func schedulePromotesExistingAndDeclinedIdeasIntoMealSlots() async throws {
    let (tripID, consideringID, declinedID) = try await database.write { db -> (Trip.ID, Idea.ID, Idea.ID) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let consideringID = UUID()
      let declinedID = UUID()
      try Idea.insert {
        [Idea.Draft(Idea(id: consideringID, name: "Considering")),
         Idea.Draft(Idea(id: declinedID, name: "Declined"))]
      }.execute(db)
      let declined = try TripIdea.pull(ideaID: declinedID, into: trip.id, in: db)
      try TripIdea.decline(stopID: declined.id, reason: nil, in: db)
      return (trip.id, consideringID, declinedID)
    }

    try await database.write { db in
      try GuideSlotAction.schedule(day: 2, .lunch).apply(ideaID: consideringID, tripID: tripID, in: db)
      try GuideSlotAction.schedule(day: 3, .dinner).apply(ideaID: declinedID, tripID: tripID, in: db)
    }
    let entries = try await database.read { db in try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db) }
    #expect(entries.count == 2)
    #expect(entries.first { $0.ideaID == consideringID }?.schedule == .daypart(2, .lunch))
    #expect(entries.first { $0.ideaID == declinedID }?.schedule == .daypart(3, .dinner))
    #expect(entries.allSatisfy { $0.status == .scheduled })
  }

  @Test func addingOptionKeepsRouteAndDetachingPreservesAndNormalizesRing() async throws {
    let ids = try await database.write { db -> (Trip.ID, [Idea.ID], TripIdea.ID) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let ideaIDs = (0..<3).map { _ in UUID() }
      try Idea.insert { ideaIDs.enumerated().map { Idea.Draft(Idea(id: $0.element, name: "Place \($0.offset)")) } }
        .execute(db)
      let target = try TripIdea.pull(ideaID: ideaIDs[0], into: trip.id, status: .scheduled, in: db)
      try TripIdea.schedule(.daypart(1, .dinner), stopID: target.id, in: db)
      try GuideSlotAction.addOption(to: target.id).apply(ideaID: ideaIDs[1], tripID: trip.id, in: db)
      let second = try #require(try TripIdea.where { $0.ideaID.eq(ideaIDs[1]) }.fetchOne(db))
      try GuideSlotAction.addOption(to: target.id).apply(ideaID: ideaIDs[2], tripID: trip.id, in: db)
      return (trip.id, ideaIDs, second.id)
    }
    var entries = try await database.read { db in try TripIdea.where { $0.tripID.eq(ids.0) }.fetchAll(db) }
    #expect(entries.count == 3)
    #expect(entries.first { $0.ideaID == ids.1[0] }?.isActive == true)
    #expect(entries.filter { !$0.isActive }.count == 2)
    try await database.write { db in try TripIdea.detachAlternative(stopID: ids.2, in: db) }
    entries = try await database.read { db in try TripIdea.where { $0.tripID.eq(ids.0) }.fetchAll(db) }
    let detached = try #require(entries.first { $0.id == ids.2 })
    let remaining = entries.filter { $0.alternativeGroupID != nil }
    #expect(detached.status == .shortlisted)
    #expect(detached.schedule == .unscheduled)
    #expect(detached.alternativeGroupID == nil)
    #expect(remaining.count == 2)
    #expect(remaining.filter(\.isActive).count == 1)
  }

  @Test func straightLineDistanceUsesTheSharedMapFramingFormula() {
    let origin = TripCoordinate(latitude: 45, longitude: 9)
    let destination = TripCoordinate(latitude: 45, longitude: 9.01)
    let distance = GuideTripLens.distanceInKilometers(from: origin, to: destination)
    #expect(distance > 0.7 && distance < 0.9)
  }
}
