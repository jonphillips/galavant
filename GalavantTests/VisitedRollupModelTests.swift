import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantPlaces
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct VisitedRollupModelTests {
  @Dependency(\.defaultDatabase) private var database

  @MainActor
  @Test(.dependencies { $0.date = .constant(Date(timeIntervalSince1970: 2_000_000_000)) })
  func geocodesOnlyTripsNearOrPastTheirCompletionBoundary() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let calendar = Calendar.current
    let regionID = UUID()
    let tripIDs = try await database.write { db -> (undated: UUID, future: UUID, past: UUID) in
      let region = MapRegion(
        id: regionID, name: "Test", centerLatitude: 55, centerLongitude: 12,
        latitudeDelta: 1, longitudeDelta: 1)
      try MapRegion.insert { MapRegion.Draft(region) }.execute(db)
      let undated = Trip(id: UUID(), name: "Undated")
      let future = Trip(
        id: UUID(), name: "Future", certaintyStage: .dated,
        startDate: calendar.date(byAdding: .day, value: 30, to: now), lengthInDays: 1)
      let past = Trip(
        id: UUID(), name: "Past", certaintyStage: .dated,
        startDate: calendar.date(byAdding: .day, value: -30, to: now), lengthInDays: 1)
      for trip in [undated, future, past] {
        try Trip.insert { Trip.Draft(trip) }.execute(db)
        try TripRegion.insert {
          TripRegion.Draft(TripRegion(id: UUID(), tripID: trip.id, regionID: regionID))
        }.execute(db)
      }
      return (undated.id, future.id, past.id)
    }

    let lookupCount = LookupCount()
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in [] },
      timeZone: { _, _ in
        await lookupCount.increment()
        return nil
      })
    let model = withDependencies {
      $0.placeMatcher = matcher
    } operation: {
      VisitedRollupModel()
    }
    await model.run()

    let count = await lookupCount.value
    #expect(count == 1)
    let markers = try await database.read { db in
      try [tripIDs.undated, tripIDs.future, tripIDs.past].map {
        try Trip.find($0).fetchOne(db)?.visitedRolledUpAt
      }
    }
    #expect(markers[0] == nil)
    #expect(markers[1] == nil)
    #expect(markers[2] == now)
  }
}

private actor LookupCount {
  private(set) var value = 0
  func increment() {
    value += 1
  }
}
