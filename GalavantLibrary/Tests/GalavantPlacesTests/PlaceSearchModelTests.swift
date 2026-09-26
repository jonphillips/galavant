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
      expectNoDifference(model.results, [.place(noma)])
    }
  }

  /// Type-ahead suggestions lead (they match the half-typed word); natural-language
  /// hits follow, minus any the completer already suggested by name.
  @Test func suggestionsLeadAndSuggestedNamesAreNotRepeated() async {
    let hotel = PlaceSuggestion(
      id: UUID(), title: "Château la Commaraine Hotel", subtitle: "Pommard, France"
    )
    let sameHotel = Place(
      id: UUID(), name: "chateau La Commaraine hotel", latitude: 47.0, longitude: 4.8
    )
    let street = Place(
      id: UUID(), name: "Route du Château", latitude: 47.1, longitude: 4.7
    )
    await withDependencies {
      $0.placeSearch.complete = { query, scope in
        expectNoDifference(query, "Chateau La Commaraine Hote")
        expectNoDifference(scope, .worldwide)
        return [hotel]
      }
      $0.placeSearch.search = { _, _ in [sameHotel, street] }
    } operation: {
      let model = PlaceSearchModel()
      model.query = "Chateau La Commaraine Hote"
      await model.searchTask?.value
      expectNoDifference(model.results, [.suggestion(hotel), .place(street)])
    }
  }

  /// A failing completer mustn't blank the list: the natural-language hits still show.
  @Test func completerFailureStillShowsSearchHits() async {
    let street = Place(id: UUID(), name: "Route du Château", latitude: 47.1, longitude: 4.7)
    struct Throttled: Error {}
    await withDependencies {
      $0.placeSearch.complete = { _, _ in throw Throttled() }
      $0.placeSearch.search = { _, _ in [street] }
    } operation: {
      let model = PlaceSearchModel()
      model.query = "route"
      await model.searchTask?.value
      expectNoDifference(model.results, [.place(street)])
    }
  }

  /// Tapping a suggestion looks it up through the client; a resolved hit passes through.
  @Test func resolvingASuggestionLooksItUp() async {
    let suggestion = PlaceSuggestion(id: UUID(), title: "Noma", subtitle: "Copenhagen")
    let noma = Place(id: UUID(), name: "Noma", latitude: 55.683, longitude: 12.610)
    await withDependencies {
      $0.placeSearch.resolve = { resolving in
        expectNoDifference(resolving, suggestion)
        return noma
      }
    } operation: {
      let model = PlaceSearchModel()
      let resolvedSuggestion = await model.resolve(.suggestion(suggestion))
      let resolvedPlace = await model.resolve(.place(noma))
      expectNoDifference(resolvedSuggestion, noma)
      expectNoDifference(resolvedPlace, noma)
    }
  }

  @Test func mergeCapsSuggestionsAndTotal() {
    let suggestions = (0..<10).map {
      PlaceSuggestion(id: UUID(), title: "Suggestion \($0)", subtitle: "")
    }
    let places = (0..<10).map {
      Place(id: UUID(), name: "Place \($0)", latitude: 0, longitude: 0)
    }
    let merged = PlaceSearchResult.merged(suggestions: suggestions, places: places)
    #expect(merged.count == 12)
    #expect(merged.prefix(8).allSatisfy { if case .suggestion = $0 { true } else { false } })
    #expect(merged.suffix(4).allSatisfy { if case .place = $0 { true } else { false } })
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
