import Foundation
import GalavantSchema
import Testing

struct IdeaTripBadgeTests {
  // MARK: Fixtures

  func idea(_ name: String = "Reffen", visited: Bool = false) -> Idea {
    Idea(id: UUID(), name: name, visited: visited)
  }

  func trip(_ name: String, _ certainty: Certainty) -> Trip {
    var trip = Trip(id: UUID(), name: name)
    trip.apply(certainty)
    return trip
  }

  func entry(_ tripID: Trip.ID, _ status: TripIdeaStatus, day: Int? = nil) -> TripIdea {
    TripIdea(id: UUID(), tripID: tripID, ideaID: UUID(), status: status, dayNumber: day)
  }

  func badge(
    _ idea: Idea,
    _ entries: [TripIdea],
    _ trips: [Trip]
  ) -> IdeaTripBadge? {
    IdeaTripBadge.badge(
      forIdea: idea,
      entries: entries,
      tripsByID: Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    )
  }

  // MARK: Tests

  @Test func freeIdeaHasNoBadge() {
    #expect(badge(idea(), [], []) == nil)
  }

  @Test func visitedOnlyShowsVisited() {
    #expect(badge(idea(visited: true), [], []) == .visited)
  }

  @Test func scheduledShowsTripAndDay() {
    let cph = trip("Copenhagen 2027", .dated(start: .now))
    let result = badge(idea(), [entry(cph.id, .scheduled, day: 3)], [cph])
    #expect(result == .scheduled(trip: "Copenhagen 2027", dayNumber: 3))
  }

  @Test func scheduledWithoutDayIsBucket() {
    let cph = trip("Copenhagen 2027", .dated(start: .now))
    let result = badge(idea(), [entry(cph.id, .scheduled, day: nil)], [cph])
    #expect(result == .scheduled(trip: "Copenhagen 2027", dayNumber: nil))
  }

  @Test func pulledOntoDatedTripIsUpcoming() {
    let paris = trip("Paris Q2", .targeted(year: 2027, quarter: .q2))
    let result = badge(idea(), [entry(paris.id, .shortlisted)], [paris])
    #expect(result == .upcoming(trip: "Paris Q2"))
  }

  @Test func pulledOntoSomedayTripIsSomeday() {
    let japan = trip("Japan", .someday(rank: 0))
    let result = badge(idea(), [entry(japan.id, .considering)], [japan])
    #expect(result == .someday(trip: "Japan"))
  }

  @Test func mostActionableStatusWins() {
    // Same idea: scheduled on one trip, merely someday on another → scheduled.
    let cph = trip("Copenhagen 2027", .dated(start: .now))
    let japan = trip("Japan", .someday(rank: 0))
    let result = badge(
      idea(visited: true),  // even with the visited flag set, a live join wins
      [entry(japan.id, .considering), entry(cph.id, .scheduled, day: 1)],
      [cph, japan]
    )
    #expect(result == .scheduled(trip: "Copenhagen 2027", dayNumber: 1))
  }

  @Test func liveAssociationOutranksVisitedFlag() {
    let japan = trip("Japan", .someday(rank: 0))
    let result = badge(idea(visited: true), [entry(japan.id, .considering)], [japan])
    #expect(result == .someday(trip: "Japan"))
  }

  @Test func doneAndSkippedJoinsAreIgnored() {
    let cph = trip("Copenhagen 2027", .dated(start: .now))
    // A done join (idea already flipped to visited) + skipped → fall back to visited.
    let result = badge(
      idea(visited: true),
      [entry(cph.id, .done), entry(cph.id, .skipped)],
      [cph]
    )
    #expect(result == .visited)
  }

  @Test func sameTierPicksSoonestTrip() {
    let early = trip("Early", .dated(start: Date(timeIntervalSince1970: 1_000)))
    let late = trip("Late", .dated(start: Date(timeIntervalSince1970: 9_000)))
    let result = badge(
      idea(),
      [entry(late.id, .scheduled, day: 2), entry(early.id, .scheduled, day: 1)],
      [early, late]
    )
    #expect(result == .scheduled(trip: "Early", dayNumber: 1))
  }
}
