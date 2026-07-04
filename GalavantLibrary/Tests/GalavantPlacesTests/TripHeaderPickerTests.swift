import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

/// The trip header picker (ADR-0032): seed → search → select-writes-Trip, driven by a
/// stubbed `UnsplashClient` and an in-memory DB (no network).
@MainActor
@Suite struct TripHeaderPickerTests {
  private nonisolated static func photo(_ id: String) -> UnsplashPhoto {
    UnsplashPhoto(
      id: id,
      thumbURL: "https://img/\(id)/thumb",
      regularURL: "https://img/\(id)/regular",
      color: "#123456",
      photographerName: "Ada",
      photographerUsername: "ada",
      downloadLocation: "https://api/\(id)/download"
    )
  }

  @Test("seeds the query from the primary region when present, else the trip name")
  func seedsQuery() {
    let regionSeeded = TripHeaderPicker(
      tripID: UUID(), tripName: "Summer 2027", primaryRegionName: "Copenhagen"
    )
    #expect(regionSeeded.query == "Copenhagen")

    let nameSeeded = TripHeaderPicker(tripID: UUID(), tripName: "Copenhagen")
    #expect(nameSeeded.query == "Copenhagen")

    let blankRegion = TripHeaderPicker(
      tripID: UUID(), tripName: "Copenhagen", primaryRegionName: "   "
    )
    #expect(blankRegion.query == "Copenhagen")
  }

  @Test("search loads the client's results")
  func searchLoads() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.unsplashClient = UnsplashClient(
        search: { _, _ in [Self.photo("a"), Self.photo("b")] },
        registerDownload: { _ in }
      )
    } operation: {
      let picker = TripHeaderPicker(tripID: UUID(), tripName: "Copenhagen")
      await picker.search()
      #expect(picker.phase == .loaded)
      #expect(picker.results.map(\.id) == ["a", "b"])
    }
  }

  @Test("a blank query does not search")
  func blankQueryIsNoOp() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.unsplashClient = UnsplashClient(
        search: { _, _ in Issue.record("should not search on blank query"); return [] },
        registerDownload: { _ in }
      )
    } operation: {
      let picker = TripHeaderPicker(tripID: UUID(), tripName: "")
      await picker.search()
      #expect(picker.phase == .idle)
      #expect(picker.results.isEmpty)
    }
  }

  @Test("a transport failure surfaces as .failed, not a throw")
  func searchFailureSurfaces() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.unsplashClient = UnsplashClient(
        search: { _, _ in throw UnsplashError.badResponse },
        registerDownload: { _ in }
      )
    } operation: {
      let picker = TripHeaderPicker(tripID: UUID(), tripName: "Copenhagen")
      await picker.search()
      if case .failed = picker.phase {} else { Issue.record("expected .failed, got \(picker.phase)") }
      #expect(picker.results.isEmpty)
    }
  }

  @Test("choosing a photo pings registerDownload then writes the reference to the trip")
  func choosePersistsAndTracks() async throws {
    let tracked = LockIsolated<[String]>([])
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.unsplashClient = UnsplashClient(
        search: { _, _ in [] },
        registerDownload: { location in tracked.withValue { $0.append(location) } }
      )
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let trip = try await database.write { db in try Trip.create(name: "Copenhagen", in: db) }

      let picker = TripHeaderPicker(tripID: trip.id, tripName: "Copenhagen")
      await picker.choose(Self.photo("hero"))

      #expect(tracked.value == ["https://api/hero/download"])
      let saved = try await database.read { db in try Trip.find(trip.id).fetchOne(db)! }
      #expect(saved.headerImage?.url == "https://img/hero/regular")
      #expect(saved.headerImage?.color == "#123456")
      #expect(saved.headerImage?.photographerName == "Ada")
      #expect(saved.headerImage?.photographerUsername == "ada")
    }
  }

  @Test("clear removes the header")
  func clearRemovesHeader() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.unsplashClient = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let trip = try await database.write { db in try Trip.create(name: "Copenhagen", in: db) }
      let picker = TripHeaderPicker(tripID: trip.id, tripName: "Copenhagen")
      await picker.choose(Self.photo("hero"))
      await picker.clear()
      let saved = try await database.read { db in try Trip.find(trip.id).fetchOne(db)! }
      #expect(saved.headerImage == nil)
    }
  }
}
