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

  @Test func applyMovesShortlistsAndCreatesTheRequestedStayRange() async throws {
    let values = try await database.write { db -> (Trip.ID, TripIdea.ID, Idea.ID, Idea.ID) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let movingID = UUID()
      let shortlistID = UUID()
      let hotelID = UUID()
      try Idea.insert {
        [Idea.Draft(Idea(id: movingID, name: "Move")),
         Idea.Draft(Idea(id: shortlistID, name: "Shortlist")),
         Idea.Draft(Idea(id: hotelID, name: "Hotel", kind: .stay))]
      }.execute(db)
      let moving = try TripIdea.pull(ideaID: movingID, into: trip.id, status: .scheduled, in: db)
      try TripIdea.schedule(.daypart(1, .dinner), stopID: moving.id, in: db)
      return (trip.id, moving.id, shortlistID, hotelID)
    }

    try await database.write { db in
      try GuideSlotAction.move(stopID: values.1, day: 2, .lunch)
        .apply(ideaID: UUID(), tripID: values.0, in: db)
      try GuideSlotAction.shortlist.apply(ideaID: values.2, tripID: values.0, in: db)
      try GuideSlotAction.stay(nights: 7...8).apply(ideaID: values.3, tripID: values.0, in: db)
    }
    let entries = try await database.read { db in try TripIdea.where { $0.tripID.eq(values.0) }.fetchAll(db) }
    let stays = try await database.read { db in try TripStay.where { $0.tripID.eq(values.0) }.fetchAll(db) }
    #expect(entries.first { $0.id == values.1 }?.schedule == .daypart(2, .lunch))
    #expect(entries.first { $0.ideaID == values.2 }?.status == .shortlisted)
    #expect(stays.count == 1)
    #expect(stays.first?.checkInDay == 7)
    #expect(stays.first?.checkOutDay == 9)
  }

  @Test func addOptionToLoneStopPreservesTheOriginalAsActive() async throws {
    let (tripID, firstID, secondID) = try await database.write { db -> (Trip.ID, Idea.ID, Idea.ID) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let firstID = UUID()
      let secondID = UUID()
      try Idea.insert {
        [Idea.Draft(Idea(id: firstID, name: "First")), Idea.Draft(Idea(id: secondID, name: "Second"))]
      }.execute(db)
      let first = try TripIdea.pull(ideaID: firstID, into: trip.id, status: .scheduled, in: db)
      try TripIdea.schedule(.daypart(1, .dinner), stopID: first.id, in: db)
      try GuideSlotAction.addOption(to: first.id).apply(ideaID: secondID, tripID: trip.id, in: db)
      return (trip.id, firstID, secondID)
    }
    let entries = try await database.read { db in try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db) }
    #expect(entries.count == 2)
    #expect(entries.first { $0.ideaID == firstID }?.isActive == true)
    #expect(entries.first { $0.ideaID == secondID }?.isActive == false)
    #expect(entries.allSatisfy { $0.alternativeGroupID != nil })
  }

  @Test func detachingActiveMemberFromTwoOptionRingDissolvesTheRing() async throws {
    let (tripID, activeID, remainingID) = try await database.write { db -> (Trip.ID, TripIdea.ID, TripIdea.ID) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let groupID = UUID()
      let members = (0..<2).map { index in
        TripIdea(id: UUID(), tripID: trip.id, ideaID: UUID(), status: .scheduled,
          shortlistRank: index, alternativeGroupID: groupID, isActive: index == 0,
          dayNumber: 1, dayPart: .dinner)
      }
      for member in members { try TripIdea.insert { TripIdea.Draft(member) }.execute(db) }
      try TripIdea.detachAlternative(stopID: members[0].id, in: db)
      return (trip.id, members[0].id, members[1].id)
    }
    let entries = try await database.read { db in try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db) }
    let detached = try #require(entries.first { $0.id == activeID })
    let remaining = try #require(entries.first { $0.id == remainingID })
    #expect(detached.status == .shortlisted)
    #expect(detached.alternativeGroupID == nil)
    #expect(detached.schedule == .unscheduled)
    #expect(remaining.alternativeGroupID == nil)
    #expect(remaining.isActive)
    #expect(TripIdea.effectiveActiveEntries([remaining]) == [remaining])
  }

  @Test func straightLineDistanceUsesTheSharedMapFramingFormula() {
    let origin = TripCoordinate(latitude: 45, longitude: 9)
    let destination = TripCoordinate(latitude: 45, longitude: 9.01)
    let distance = GuideTripLens.distanceInKilometers(from: origin, to: destination)
    #expect(distance > 0.7 && distance < 0.9)
  }

  @Test func distanceFromStayCoversLocatedNoStayAndUnlocatedCases() throws {
    let trip = Trip(id: UUID(), name: "Bavaria", lengthInDays: 3)
    let restaurant = Idea(id: UUID(), name: "Restaurant", latitude: 45, longitude: 9.01)
    let hotel = Idea(id: UUID(), name: "Hotel", kind: .stay, latitude: 45, longitude: 9)
    let stay = TripStay(id: UUID(), tripID: trip.id, ideaID: hotel.id, checkInDay: 1, checkOutDay: 3)
    let ideas = [restaurant, hotel]
    let plan = TripPlan(entries: [], ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }),
      lengthInDays: trip.lengthInDays, tripStays: [stay])
    let result = try #require(GuideTripLens.distanceFromStay(
      day: 1, ideaID: restaurant.id, plan: plan, stays: [stay], ideas: ideas))
    #expect(result.hotelName == "Hotel")
    #expect(result.distance.converted(to: .kilometers).value > 0.7)
    #expect(result.distance.converted(to: .kilometers).value < 0.9)

    let noStayPlan = TripPlan(entries: [], ideasByID: plan.ideasByID, lengthInDays: trip.lengthInDays)
    #expect(GuideTripLens.distanceFromStay(
      day: 1, ideaID: restaurant.id, plan: noStayPlan, stays: [], ideas: ideas) == nil)
    let unlocated = Idea(id: UUID(), name: "Unlocated")
    #expect(GuideTripLens.distanceFromStay(
      day: 1, ideaID: unlocated.id, plan: plan, stays: [stay], ideas: ideas + [unlocated]) == nil)
  }
}
