import Dependencies
import Foundation
import Testing

@testable import GalavantPlaces

@MainActor
@Suite struct PlaceSearchModelTests {
  /// The pattern: override the injected `PlaceSearchClient` with a fixture so the
  /// model can be exercised with no MapKit / no network. Establishes how app-layer
  /// `@Observable` models get tested once they live in the package.
  @Test func querySurfacesResultsFromTheClient() async {
    let noma = Place(
      id: UUID(),
      name: "Noma",
      latitude: 55.683,
      longitude: 12.610,
      regionName: "Copenhagen",
      kind: .food,
      address: "Refshalevej 96, Copenhagen"
    )
    await withDependencies {
      $0.placeSearch.search = { query in
        #expect(query == "noma")
        return [noma]
      }
    } operation: {
      let model = PlaceSearchModel()
      model.query = "noma"
      await model.searchTask?.value
      #expect(model.results == [noma])
    }
  }

  /// A one-character query is below the threshold: no search fires, results clear.
  @Test func shortQueryDoesNotSearch() async {
    await withDependencies {
      $0.placeSearch.search = { _ in
        Issue.record("search should not run for a sub-threshold query")
        return []
      }
    } operation: {
      let model = PlaceSearchModel()
      model.query = "n"
      await model.searchTask?.value
      #expect(model.results.isEmpty)
    }
  }
}
