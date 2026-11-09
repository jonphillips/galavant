import Foundation
import GalavantSchema
import Testing

@testable import Galavant

struct RouteIdeasSnapshotTests {
  @Test func candidatesExcludeSameDayDeclinedAndStaysButKeepOtherDay() {
    let tripID = UUID()
    let onDay = Idea(id: UUID(), name: "On Wednesday", latitude: 1, longitude: 1)
    let anotherDay = Idea(id: UUID(), name: "On Thursday", latitude: 1, longitude: 1)
    let declined = Idea(id: UUID(), name: "Ruled out", latitude: 1, longitude: 1)
    let stay = Idea(id: UUID(), name: "Hotel", kind: .stay, latitude: 1, longitude: 1)
    let noLocation = Idea(id: UUID(), name: "Unlocated")
    let entries = [
      TripIdea(id: UUID(), tripID: tripID, ideaID: onDay.id, status: .scheduled, dayNumber: 2),
      TripIdea(id: UUID(), tripID: tripID, ideaID: anotherDay.id, status: .scheduled, dayNumber: 3),
      TripIdea(id: UUID(), tripID: tripID, ideaID: declined.id, status: .declined),
    ]

    let candidates = RouteIdeaCandidates.filter(
      ideas: [onDay, anotherDay, declined, stay, noLocation], tripIdeas: entries, day: 2)

    #expect(candidates.map(\.id) == [anotherDay.id])
  }

  @Test func geometryBuildsAgainOnlyWhenInputsChange() {
    var snapshot = RouteIdeasSnapshot()
    let route = [
      TravelEndpoint(id: "a", title: "A", latitude: 0, longitude: 0),
      TravelEndpoint(id: "b", title: "B", latitude: 0, longitude: 1),
    ]
    let candidate = Idea(id: UUID(), latitude: 0, longitude: 0.5)

    _ = snapshot.matches(route: route, candidates: [candidate])
    _ = snapshot.matches(route: route, candidates: [candidate])
    #expect(snapshot.buildCount == 1)

    _ = snapshot.matches(route: route, candidates: [])
    #expect(snapshot.buildCount == 2)
  }
}
