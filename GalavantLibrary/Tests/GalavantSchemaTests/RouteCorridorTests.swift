import Foundation
import Dependencies
import DependenciesTestSupport
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies {
  try $0.bootstrapDatabase()
  $0.uuid = .incrementing
})
struct RouteCorridorTests {
  @Dependency(\.defaultDatabase) var database

  @Test func measuresBesideSegmentMiddle() {
    let route = [endpoint(0, 0), endpoint(0, 1)]
    let idea = idea(latitude: 0.05, longitude: 0.5)

    let match = RouteCorridor.matches(route: route, ideas: [idea], widthMeters: 6_000)

    #expect(match.count == 1)
    #expect(abs(match[0].distanceMeters - 5_560) < 30)
    #expect(abs(match[0].progress - 0.5) < 0.001)
  }

  @Test func clampsProjectionPastSegmentEndToEndpoint() {
    let route = [endpoint(0, 0), endpoint(0, 1)]
    let idea = idea(latitude: 0, longitude: 1.1)

    let match = RouteCorridor.matches(route: route, ideas: [idea], widthMeters: 12_000)

    #expect(match.count == 1)
    #expect(abs(match[0].distanceMeters - 11_120) < 30)
    #expect(match[0].progress == 1)
  }

  @Test func excludesIdeasOutsideWidthAndWithoutCoordinates() {
    let ideas = [idea(latitude: 0.14, longitude: 0.5), idea(latitude: nil, longitude: 0.5)]

    #expect(RouteCorridor.matches(route: [endpoint(0, 0), endpoint(0, 1)], ideas: ideas).isEmpty)
  }

  @Test func onePointRouteIsACircleAndEmptyRouteNeverMatches() {
    let idea = idea(latitude: 0, longitude: 0.1)

    #expect(RouteCorridor.matches(route: [endpoint(0, 0)], ideas: [idea]).count == 1)
    #expect(RouteCorridor.matches(route: [], ideas: [idea]).isEmpty)
  }

  @Test func ordersByProgressAlongThreePointRoute() {
    let route = [endpoint(0, 0), endpoint(0, 1), endpoint(1, 1)]
    let later = idea(latitude: 0.5, longitude: 1)
    let earlier = idea(latitude: 0, longitude: 0.25)

    let matches = RouteCorridor.matches(route: route, ideas: [later, earlier])

    #expect(matches.map(\.ideaID) == [earlier.id, later.id])
    #expect(matches[0].progress < matches[1].progress)
  }

  @Test func pullingAndSchedulingAddsOrMovesIdeaToTargetDay() async throws {
    let (newStop, movedStop, untouchedStop, expectedMovedID) = try await database.write {
      db -> (TripIdea, TripIdea, TripIdea, TripIdea.ID) in
      let trip = try Trip.create(name: "Transfer", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let newID = UUID()
      let movedID = UUID()
      try Idea.insert {
        [
          Idea.Draft(Idea(id: newID, name: "New", travelPartyID: party.id)),
          Idea.Draft(Idea(id: movedID, name: "Moved", travelPartyID: party.id)),
        ]
      }.execute(db)
      let existing = try TripIdea.pull(ideaID: movedID, into: trip.id, status: .scheduled, in: db)
      try TripIdea.schedule(.day(3), stopID: existing.id, in: db)
      let otherOccurrence = try TripIdea.repeatScheduled(
        ideaID: movedID, into: trip.id, on: .day(4), in: db)

      try TripIdea.applyRouteIdeaAction(.add(ideaID: newID), into: trip.id, on: 2, in: db)
      try TripIdea.applyRouteIdeaAction(
        .move(ideaID: movedID, stopID: existing.id), into: trip.id, on: 2, in: db)
      let added = try TripIdea.where { $0.ideaID.eq(newID) }.fetchOne(db)
      let moved = try TripIdea.find(existing.id).fetchOne(db)
      let untouchedOccurrence = try TripIdea.find(otherOccurrence.id).fetchOne(db)
      return (
        try #require(added),
        try #require(moved),
        try #require(untouchedOccurrence),
        existing.id)
    }

    #expect(newStop.status == .scheduled)
    #expect(newStop.schedule == .day(2))
    #expect(movedStop.status == .scheduled)
    #expect(movedStop.id == expectedMovedID)
    #expect(movedStop.schedule == .day(2))
    #expect(untouchedStop.schedule == .day(4))
  }

  private func endpoint(_ latitude: Double, _ longitude: Double) -> TravelEndpoint {
    TravelEndpoint(id: UUID().uuidString, title: "Route", latitude: latitude, longitude: longitude)
  }

  private func idea(latitude: Double?, longitude: Double?) -> Idea {
    Idea(id: UUID(), latitude: latitude, longitude: longitude)
  }
}
