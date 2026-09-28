import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

/// Relaunch after iPadOS kills the app in the background: the router reopens the
/// section and trip the scene's `@SceneStorage` remembered, re-fetching the trip
/// by id rather than trusting a stored copy.
@Suite(.dependencies { try $0.bootstrapDatabase() })
@MainActor
struct AppRouterRestoreTests {
  @Dependency(\.defaultDatabase) private var database

  private func makeTrip(name: String) async throws -> Trip.ID {
    let tripID = UUID()
    try await database.write { db in
      try Trip.insert { Trip.Draft(Trip(id: tripID, name: name)) }.execute(db)
    }
    return tripID
  }

  @Test
  func reopensTheStoredSectionAndTrip() async throws {
    let tripID = try await makeTrip(name: "Dolomites")
    let router = AppRouter()

    router.restore(selection: .evaluate, openTripID: tripID)

    #expect(router.selection == .evaluate)
    #expect(router.openTrip?.id == tripID)
    #expect(router.openTrip?.name == "Dolomites")
  }

  @Test
  func aTripDeletedMeanwhileStaysClosed() {
    let router = AppRouter()

    router.restore(selection: .trips, openTripID: UUID())

    #expect(router.selection == .trips)
    #expect(router.openTrip == nil)
  }

  @Test
  func nothingStoredKeepsTheDefaults() {
    let router = AppRouter()

    router.restore(selection: nil, openTripID: nil)

    #expect(router.selection == .trips)
    #expect(router.openTrip == nil)
  }

  @Test
  func neverOverridesATripAlreadyOpen() async throws {
    let openID = try await makeTrip(name: "Open")
    let storedID = try await makeTrip(name: "Stored")
    let router = AppRouter()
    router.restore(selection: nil, openTripID: openID)

    router.restore(selection: nil, openTripID: storedID)

    #expect(router.openTrip?.id == openID)
  }
}
