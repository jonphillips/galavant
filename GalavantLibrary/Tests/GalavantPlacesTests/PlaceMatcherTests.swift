import Foundation
import GalavantCapture
import Testing

@testable import GalavantPlaces

@Suite struct PlaceMatcherTests {
  private func place(_ name: String, _ lat: Double, _ lon: Double, address: String? = nil) -> Place {
    Place(id: UUID(), name: name, latitude: lat, longitude: lon, address: address)
  }

  @Test("Scraped coordinates are authoritative — no geocode or search")
  func coordinatesWinOutright() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("geocode should not run"); return nil },
      search: { _ in Issue.record("search should not run"); return [] }
    )
    let page = ParsedPage(
      title: "Noma",
      coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109),
      address: ParsedAddress(street: "Refshalevej 96", locality: "Copenhagen")
    )
    let match = await matcher.match(page)
    #expect(match == LocationMatch(coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109)))
  }

  @Test("No coordinates: geocode the address before falling to search")
  func geocodeBeforeSearch() async {
    let matcher = PlaceMatcher(
      geocode: { _ in ParsedCoordinate(latitude: 10, longitude: 20) },
      search: { _ in Issue.record("search should not run once geocode succeeds"); return [] }
    )
    let page = ParsedPage(title: "X", address: ParsedAddress(street: "A St", locality: "Town"))
    let match = await matcher.match(page)
    #expect(match?.coordinate == ParsedCoordinate(latitude: 10, longitude: 20))
  }

  @Test("Text search picks the best-scoring hit, not just the first")
  func textSearchScores() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("no address to geocode"); return nil },
      search: { _ in
        [
          self.place("Random Cafe", 1, 1),
          self.place("Noma", 55.6839, 12.6109),
        ]
      }
    )
    let page = ParsedPage(title: "Noma Restaurant")
    let match = await matcher.match(page)
    #expect(match?.name == "Noma")
    #expect(match?.coordinate == ParsedCoordinate(latitude: 55.6839, longitude: 12.6109))
  }

  @Test("A best hit below the confidence floor is rejected")
  func belowThresholdRejected() async {
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in [self.place("Pizza Hut", 1, 1)] }
    )
    let page = ParsedPage(title: "Noma")
    #expect(await matcher.match(page) == nil)
  }

  @Test("A page with no signal resolves to nil")
  func noSignal() async {
    let matcher = PlaceMatcher(geocode: { _ in nil }, search: { _ in [] })
    #expect(await matcher.match(ParsedPage()) == nil)
  }
}
