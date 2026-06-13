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
