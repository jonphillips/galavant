import Foundation
import GalavantSchema
import Testing

/// The per-day "add" picker's region scoping (dogfood #5): `TripPlan.stops(_:inRegionForDay:)`
/// narrows a set of resolved stops to the region assigned to a day, so you only
/// see ideas that belong there — with the whole set surviving when the day has no
/// region (or is the To-Be-Scheduled bucket).
@Suite struct PlaceIdeaDayRegionTests {
  private let tripID = UUID()

  // Two disjoint regions: north and south of the equator, non-overlapping boxes.
  private let northID = UUID()
  private let southID = UUID()
  private var north: MapRegion {
    MapRegion(id: northID, name: "North", centerLatitude: 50, centerLongitude: 0,
              latitudeDelta: 4, longitudeDelta: 4)
  }
  private var south: MapRegion {
    MapRegion(id: southID, name: "South", centerLatitude: 10, centerLongitude: 0,
              latitudeDelta: 4, longitudeDelta: 4)
  }

  private func shortlistEntry(_ ideaID: Idea.ID, rank: Int) -> TripIdea {
    TripIdea(id: UUID(), tripID: tripID, ideaID: ideaID, status: .shortlisted, shortlistRank: rank)
  }

  private func plan(ideas: [Idea], dayRegions: [TripDayRegion]) -> TripPlan {
    let entries = ideas.enumerated().map { shortlistEntry($0.element.id, rank: $0.offset) }
    return TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: 3,
      dayRegions: dayRegions,
      regionsByID: [northID: north, southID: south]
    )
  }

  private func idea(_ name: String, lat: Double?, lon: Double?) -> Idea {
    Idea(id: UUID(), name: name, kind: .food, latitude: lat, longitude: lon)
  }

  @Test func regionScopedDayShowsOnlyIdeasInsideThatRegion() {
    let inNorth = idea("Oslo café", lat: 50, lon: 0)
    let inSouth = idea("Lagos café", lat: 10, lon: 0)
    let unlocated = idea("Someday café", lat: nil, lon: nil)
    let p = plan(
      ideas: [inNorth, inSouth, unlocated],
      dayRegions: [TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: northID)]
    )
    // Day 1 is scoped to North: only the northern idea survives; the southern and
    // the unlocated ones drop.
    #expect(p.stops(p.shortlist, inRegionForDay: 1).map(\.idea!.name) == ["Oslo café"])
  }

  @Test func dayWithoutARegionImposesNoConstraint() {
    let inNorth = idea("Oslo café", lat: 50, lon: 0)
    let inSouth = idea("Lagos café", lat: 10, lon: 0)
    let unlocated = idea("Someday café", lat: nil, lon: nil)
    let p = plan(ideas: [inNorth, inSouth, unlocated], dayRegions: [])  // day 2 unassigned
    #expect(
      p.stops(p.shortlist, inRegionForDay: 2).map(\.idea!.name)
        == ["Oslo café", "Lagos café", "Someday café"])
  }

  @Test func toBeScheduledBucketShowsEverything() {
    let inNorth = idea("Oslo café", lat: 50, lon: 0)
    let inSouth = idea("Lagos café", lat: 10, lon: 0)
    let p = plan(
      ideas: [inNorth, inSouth],
      // Even with a day-1 region present, the nil bucket is unconstrained.
      dayRegions: [TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: northID)]
    )
    #expect(p.stops(p.shortlist, inRegionForDay: nil).map(\.idea!.name) == ["Oslo café", "Lagos café"])
  }
}
