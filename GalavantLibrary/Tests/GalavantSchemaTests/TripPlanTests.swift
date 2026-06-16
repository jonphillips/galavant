import Foundation
import GalavantSchema
import Testing

/// `TripPlan` is the pure read-model that joins this trip's `TripIdea` entries to
/// their pool ideas and partitions them for the planning surfaces. These tests
/// exercise it as a plain value — no database, no `@Observable` — which is the
/// whole point of pulling the join out of `TripPlanningModel`.
@Suite struct TripPlanTests {
  // A located idea by default, so the canvas-geometry projections have something
  // to plot; pass nil coords for the unlocated cases.
  func idea(
    _ id: Idea.ID, name: String = "", lat: Double? = 1, lon: Double? = 1
  ) -> Idea {
    Idea(id: id, name: name, latitude: lat, longitude: lon)
  }

  func entry(
    idea: Idea.ID,
    status: TripIdeaStatus,
    rank: Int = 0,
    schedule: Schedule = .unscheduled
  ) -> TripIdea {
    var e = TripIdea(id: UUID(), tripID: UUID(), ideaID: idea, status: status, shortlistRank: rank)
    e.apply(schedule)
    return e
  }

  func plan(_ entries: [TripIdea], ideas: [Idea], lengthInDays: Int = 3) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: lengthInDays
    )
  }

  @Test func shortlistIsRankOrderedAndScheduledExcluded() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .shortlisted, rank: 2),
      entry(idea: b, status: .shortlisted, rank: 0),
      entry(idea: c, status: .scheduled, rank: 1, schedule: .day(1)),  // not on shortlist
    ]
    let p = plan(entries, ideas: [idea(a), idea(b), idea(c)])
    #expect(p.shortlist.map(\.idea.id) == [b, a])
  }

  @Test func scheduledOrdersByDayThenTimeOfDay() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .daypart(2, .lunch)),
      entry(idea: b, status: .scheduled, schedule: .day(1)),
      entry(idea: c, status: .scheduled, schedule: .timed(1, start: "08:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(a), idea(b), idea(c)])
    #expect(p.scheduled.map(\.idea.id) == [c, b, a])  // day1 08:00, day1 bare, day2 lunch
  }

  @Test func orphanEntriesAreDroppedFromEveryProjection() {
    // An entry whose idea isn't in the pool lookup (deleted, ADR-0007) resolves
    // to nothing and must not appear anywhere.
    let (kept, orphan) = (UUID(), UUID())
    let entries = [
      entry(idea: kept, status: .shortlisted),
      entry(idea: orphan, status: .shortlisted, rank: 1),
      entry(idea: orphan, status: .scheduled, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [idea(kept)])  // orphan absent
    #expect(p.shortlist.map(\.idea.id) == [kept])
    #expect(p.itinerary.flatMap(\.stops).isEmpty)
  }

  @Test func emptyIsTrueOnlyWithNothingPulled() {
    let bare = plan([], ideas: [])
    #expect(bare.isEmpty)
    #expect(!bare.hasScheduledStops)

    let id = UUID()
    let one = plan([entry(idea: id, status: .considering)], ideas: [idea(id)])
    #expect(!one.isEmpty)
    #expect(one.considering.map(\.idea.id) == [id])
  }

  @Test func toBeScheduledIsScheduledWithoutADay() {
    let (placed, unplaced) = (UUID(), UUID())
    let entries = [
      entry(idea: placed, status: .scheduled, schedule: .day(1)),
      entry(idea: unplaced, status: .scheduled, schedule: .unscheduled),  // committed, no day
    ]
    let p = plan(entries, ideas: [idea(placed), idea(unplaced)])
    #expect(p.toBeScheduled.map(\.idea.id) == [unplaced])
    #expect(p.hasScheduledStops)
  }

  @Test func canvasGeometryDropsUnlocatedStops() {
    let (located, unlocated) = (UUID(), UUID())
    let entries = [
      entry(idea: located, status: .scheduled, schedule: .day(1)),
      entry(idea: unlocated, status: .scheduled, rank: 1, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [idea(located), idea(unlocated, lat: nil, lon: nil)])
    #expect(p.hasLocatedStops)
    #expect(p.locatedStops(forDay: 1).map(\.idea.id) == [located])
    #expect(p.framingCoordinates(forDay: 1).count == 1)
    #expect(p.framingCoordinates(forDay: nil).count == 1)  // whole trip
  }

  @Test func itineraryHasEveryDayEvenWhenEmpty() {
    let id = UUID()
    let p = plan([entry(idea: id, status: .scheduled, schedule: .day(2))], ideas: [idea(id)], lengthInDays: 3)
    #expect(p.itinerary.map(\.number) == [1, 2, 3])
    #expect(p.itinerary[0].stops.isEmpty)
    #expect(p.itinerary[1].stops.map(\.idea.id) == [id])
  }
}
