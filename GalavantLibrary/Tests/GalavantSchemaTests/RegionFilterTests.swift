import Foundation
import GalavantSchema
import Testing

struct RegionFilterTests {
  // A ~2° box centered on Copenhagen.
  let copenhagen = MapRegion(
    id: UUID(),
    name: "Copenhagen",
    centerLatitude: 55.6761,
    centerLongitude: 12.5683,
    latitudeDelta: 2,
    longitudeDelta: 2
  )

  @Test func containmentInsideAndOutside() {
    #expect(copenhagen.contains(latitude: 55.67, longitude: 12.57))  // Tivoli, inside
    #expect(!copenhagen.contains(latitude: 40.7, longitude: -74.0))  // NYC, outside
    #expect(!copenhagen.contains(latitude: 55.67, longitude: 20.0))  // same lat, far east
  }

  @Test func regionFilterKeepsOnlyContainedLocatedIdeas() {
    let inside = idea(name: "Tivoli", lat: 55.67, lon: 12.57)
    let outside = idea(name: "Central Park", lat: 40.78, lon: -73.96)
    let unlocated = idea(name: "Someday spa", lat: nil, lon: nil)
    let result = poolFiltered([inside, outside, unlocated], regions: [copenhagen])
    #expect(result.map(\.name) == ["Tivoli"])
  }

  @Test func kindFilter() {
    let food = idea(name: "Noma", kind: .food)
    let museum = idea(name: "SMK", kind: .museum)
    let result = poolFiltered([food, museum], kinds: [.food])
    #expect(result.map(\.name) == ["Noma"])
  }

  @Test func kindGroupMappingCoversEveryKindAndUnspecified() {
    for kind in IdeaKind.allCases {
      let expected: IdeaKindGroup = switch kind {
      case .food, .drink: .food
      case .stay: .stay
      case .sight, .tour, .activity, .beach, .park, .outdoorTrail, .museum, .theater,
        .nightlife, .shop, .market, .transit: .other
      }
      #expect(IdeaKindGroup(kind: kind) == expected)
    }
    #expect(IdeaKindGroup(kind: nil) == .other)
  }

  @Test func kindGroupFiltersUnionAndCombineWithOtherFilters() {
    let food = idea(name: "Noma", kind: .food)
    let drink = idea(name: "Wine bar", kind: .drink)
    let stay = idea(name: "Hotel", kind: .stay)
    let other = idea(name: "Museum", kind: .museum)
    let unspecified = idea(name: "Someday", kind: nil)
    let ideas = [food, drink, stay, other, unspecified]

    #expect(poolFiltered(ideas, kindGroups: []).map(\.name) == ideas.map(\.name))
    #expect(poolFiltered(ideas, kindGroups: [.food]).map(\.name) == ["Noma", "Wine bar"])
    #expect(
      Set(poolFiltered(ideas, kindGroups: [.food, .stay]).map(\.name)) == ["Noma", "Wine bar", "Hotel"]
    )
    #expect(
      Set(poolFiltered(ideas, kindGroups: [.other]).map(\.name)) == ["Museum", "Someday"]
    )
    #expect(poolFiltered(ideas, kinds: [.drink], kindGroups: [.food]).map(\.name) == ["Wine bar"])
    let locatedFood = idea(name: "Located cafe", kind: .food, lat: 55.67, lon: 12.57)
    let outsideFood = idea(name: "Far cafe", kind: .food, lat: 40.7, lon: -74)
    #expect(
      poolFiltered([locatedFood, outsideFood], regions: [copenhagen], kindGroups: [.food])
        .map(\.name) == ["Located cafe"]
    )
  }

  @Test func visitedExclusion() {
    let fresh = idea(name: "Fresh", visited: false)
    let been = idea(name: "Been there", visited: true)
    let result = poolFiltered([fresh, been], includeVisited: false)
    #expect(result.map(\.name) == ["Fresh"])
  }

  @Test func multipleRegionsUnion() {
    let nyc = MapRegion(
      id: UUID(), name: "NYC",
      centerLatitude: 40.7, centerLongitude: -74.0, latitudeDelta: 2, longitudeDelta: 2
    )
    let inCph = idea(name: "Tivoli", lat: 55.67, lon: 12.57)
    let inNyc = idea(name: "Central Park", lat: 40.78, lon: -73.96)
    let elsewhere = idea(name: "Tokyo Tower", lat: 35.66, lon: 139.74)
    // An idea matches if it's inside *any* of the trip's regions.
    let result = poolFiltered([inCph, inNyc, elsewhere], regions: [copenhagen, nyc])
    #expect(Set(result.map(\.name)) == ["Tivoli", "Central Park"])
  }

  @Test func noFiltersReturnsEverything() {
    let all = [idea(name: "A"), idea(name: "B", lat: nil, lon: nil)]
    #expect(poolFiltered(all).count == 2)
  }

  @Test func pinnedIdeasBypassRegionButNotOtherFilters() {
    let inside = idea(name: "Tivoli", lat: 55.67, lon: 12.57)
    // Pulled onto the trip but outside its region (e.g. captured straight onto it).
    let pulledOutside = idea(name: "Alouette", kind: .food, lat: 40.78, lon: -73.96)
    let unpulledOutside = idea(name: "Central Park", lat: 40.78, lon: -73.96)
    // The pinned idea shows despite being outside the region; the un-pinned one doesn't.
    let result = poolFiltered(
      [inside, pulledOutside, unpulledOutside],
      regions: [copenhagen],
      pinnedIDs: [pulledOutside.id]
    )
    #expect(Set(result.map(\.name)) == ["Tivoli", "Alouette"])
    // Pinned still respects other filters: a kind filter excluding it wins.
    let kindFiltered = poolFiltered(
      [inside, pulledOutside],
      regions: [copenhagen],
      kinds: [.museum],
      pinnedIDs: [pulledOutside.id]
    )
    #expect(kindFiltered.isEmpty)  // Tivoli has no kind; Alouette is food, not museum
  }

  @Test func pinnedIdeasRespectNarrowedRegionLens() {
    let inside = idea(name: "Tivoli", lat: 55.67, lon: 12.57)
    let pulledOutside = idea(name: "Alouette", lat: 40.78, lon: -73.96)

    let fullTripLens = poolFiltered(
      [inside, pulledOutside],
      regions: [copenhagen],
      pinnedIDs: [pulledOutside.id]
    )
    let subregionLens = poolFiltered(
      [inside, pulledOutside],
      regions: [copenhagen],
      pinnedIDs: []
    )

    #expect(fullTripLens.map(\.name) == ["Tivoli", "Alouette"])
    #expect(subregionLens.map(\.name) == ["Tivoli"])
  }

  private func idea(
    name: String,
    kind: IdeaKind? = nil,
    visited: Bool = false,
    lat: Double? = 0,
    lon: Double? = 0
  ) -> Idea {
    Idea(id: UUID(), name: name, kind: kind, latitude: lat, longitude: lon, visited: visited)
  }
}
