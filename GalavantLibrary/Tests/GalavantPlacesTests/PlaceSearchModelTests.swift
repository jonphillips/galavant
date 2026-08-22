import CustomDump
import Dependencies
import Foundation
import GalavantSchema
import MapKit
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
      $0.placeSearch.search = { query, scope in
        expectNoDifference(query, "noma")
        expectNoDifference(scope, .worldwide)
        return [noma]
      }
    } operation: {
      let model = PlaceSearchModel()
      model.query = "noma"
      await model.searchTask?.value
      expectNoDifference(model.results, [noma])
    }
  }

  /// A one-character query is below the threshold: no search fires, results clear.
  @Test func shortQueryDoesNotSearch() async {
    await withDependencies {
      $0.placeSearch.search = { _, _ in
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

  @Test func queryUsesTheSuppliedTripRegions() async {
    let dolomites = MapRegion(
      id: UUID(), name: "Dolomites",
      centerLatitude: 46.5, centerLongitude: 11.8,
      latitudeDelta: 1, longitudeDelta: 1
    )
    await withDependencies {
      $0.placeSearch.search = { query, scope in
        expectNoDifference(query, "es:senz")
        expectNoDifference(scope, .regions([dolomites]))
        return []
      }
    } operation: {
      let model = PlaceSearchModel(regions: [dolomites])
      model.query = "es:senz"
      await model.searchTask?.value
    }
  }

  @Test func queryCanBiasTowardTripRegions() async {
    let dolomites = MapRegion(
      id: UUID(), name: "Dolomites",
      centerLatitude: 46.5, centerLongitude: 11.8,
      latitudeDelta: 1, longitudeDelta: 1
    )
    await withDependencies {
      $0.placeSearch.search = { query, scope in
        expectNoDifference(query, "mittenwald")
        expectNoDifference(scope, .biasedRegions([dolomites]))
        return []
      }
    } operation: {
      let model = PlaceSearchModel(regions: [dolomites], biased: true)
      model.query = "mittenwald"
      await model.searchTask?.value
    }
  }

  @Test func regionScopesKeepRequiredSemanticsSeparateFromBiasedRegions() {
    let region = MapRegion(
      id: UUID(), name: "Dolomites",
      centerLatitude: 46.5, centerLongitude: 11.8,
      latitudeDelta: 1, longitudeDelta: 1
    )

    let required = PlaceSearchClient.searchRegions(for: .regions([region]))
    let biased = PlaceSearchClient.searchRegions(for: .biasedRegions([region]))

    #expect(required.count == 1)
    #expect(required[0].required)
    #expect(biased.count == 1)
    #expect(!biased[0].required)
  }

  @Test func changingRegionsPreservesBiasedScope() async {
    let first = MapRegion(
      id: UUID(), name: "Dolomites",
      centerLatitude: 46.5, centerLongitude: 11.8,
      latitudeDelta: 1, longitudeDelta: 1
    )
    let second = MapRegion(
      id: UUID(), name: "Bavaria",
      centerLatitude: 47.5, centerLongitude: 11.3,
      latitudeDelta: 1, longitudeDelta: 1
    )
    let scopes = LockIsolated<[PlaceSearchScope]>([])
    await withDependencies {
      $0.placeSearch.search = { _, scope in
        scopes.withValue { $0.append(scope) }
        return []
      }
    } operation: {
      let model = PlaceSearchModel(regions: [first], biased: true)
      model.query = "mittenwald"
      await model.searchTask?.value

      model.regionsChanged([second])
      await model.searchTask?.value

      expectNoDifference(scopes.value, [.biasedRegions([first]), .biasedRegions([second])])
    }
  }

  @Test func changingTheViewportRerunsTheCurrentQuery() async {
    let first = PlaceSearchViewport(
      centerLatitude: 38.9,
      centerLongitude: -77.0,
      latitudeDelta: 0.5,
      longitudeDelta: 0.5
    )
    let second = PlaceSearchViewport(
      centerLatitude: 38.8,
      centerLongitude: -77.1,
      latitudeDelta: 0.25,
      longitudeDelta: 0.25
    )
    let scopes = LockIsolated<[PlaceSearchScope]>([])
    await withDependencies {
      $0.placeSearch.search = { _, scope in
        scopes.withValue { $0.append(scope) }
        return []
      }
    } operation: {
      let model = PlaceSearchModel(viewport: first)
      model.query = "coffee"
      await model.searchTask?.value

      model.visibleRegionChanged(second)
      await model.searchTask?.value

      expectNoDifference(scopes.value, [.viewport(first), .viewport(second)])
    }
  }
}
