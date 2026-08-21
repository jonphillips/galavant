import Foundation
import Testing

@testable import GalavantSchema

@Suite struct RecommendationCandidateSearchTests {
  private func region(_ name: String, lat: Double, lon: Double) -> MapRegion {
    MapRegion(
      id: UUID(),
      name: name,
      centerLatitude: lat,
      centerLongitude: lon,
      latitudeDelta: 1,
      longitudeDelta: 1
    )
  }

  @Test func localityWinsAsAGenerousBoxAroundThePoint() {
    let trip = [region("Dolomites", lat: 46.5, lon: 11.8)]
    let regions = RecommendationCandidateSearch.searchRegions(
      localityLatitude: 45.44,
      localityLongitude: 12.34,
      tripRegions: trip
    )
    #expect(regions.count == 1)
    let box = try! #require(regions.first)
    #expect(box.id == RecommendationCandidateSearch.localityRegionID)
    #expect(box.centerLatitude == 45.44)
    #expect(box.centerLongitude == 12.34)
    #expect(box.latitudeDelta == RecommendationCandidateSearch.localitySpanDegrees)
    #expect(box.longitudeDelta == RecommendationCandidateSearch.localitySpanDegrees)
  }

  @Test func fallsBackToTripRegionsWhenLocalityIsUnknown() {
    let trip = [
      region("Dolomites", lat: 46.5, lon: 11.8),
      region("Venice", lat: 45.44, lon: 12.34),
    ]
    let regions = RecommendationCandidateSearch.searchRegions(
      localityLatitude: nil,
      localityLongitude: nil,
      tripRegions: trip
    )
    #expect(regions == trip)
  }

  @Test func emptyWhenNeitherLocalityNorTripRegionsExist() {
    let regions = RecommendationCandidateSearch.searchRegions(
      localityLatitude: nil,
      localityLongitude: nil,
      tripRegions: []
    )
    #expect(regions.isEmpty)
  }

  /// A partial locality (one coordinate missing) must not synthesize a box at 0/0 —
  /// it degrades to the trip regions like a fully-missing locality.
  @Test func partialLocalityDegradesToTripRegions() {
    let trip = [region("Dolomites", lat: 46.5, lon: 11.8)]
    let regions = RecommendationCandidateSearch.searchRegions(
      localityLatitude: 45.44,
      localityLongitude: nil,
      tripRegions: trip
    )
    #expect(regions == trip)
  }
}
