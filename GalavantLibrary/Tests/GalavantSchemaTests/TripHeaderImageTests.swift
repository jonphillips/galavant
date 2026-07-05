import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

/// The trip header-image reference (ADR-0032): four flat columns on `Trip` set and
/// cleared together, folded to an all-or-nothing `TripHeaderImage` value.
@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripHeaderImageTests {
  @Dependency(\.defaultDatabase) var database

  @Test("a fresh trip has no header")
  func noHeaderByDefault() async throws {
    let trip = try await database.write { db in
      try Trip.create(name: "Copenhagen", in: db)
    }
    #expect(trip.headerImage == nil)
  }

  @Test("setHeaderImage writes all four columns and reads back as a value")
  func setRoundTrips() async throws {
    let image = TripHeaderImage(
      url: "https://images.unsplash.com/photo-1.jpg",
      color: "#1A2B3C",
      photographerName: "Ada Lovelace",
      photographerUsername: "ada"
    )
    let trip = try await database.write { db -> Trip in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      try Trip.setHeaderImage(image, tripID: trip.id, in: db)
      return try Trip.find(trip.id).fetchOne(db)!
    }
    #expect(trip.headerImageURL == image.url)
    #expect(trip.headerImageColor == "#1A2B3C")
    #expect(trip.headerPhotographerName == "Ada Lovelace")
    #expect(trip.headerPhotographerUsername == "ada")
    #expect(trip.headerImage == image)
  }

  @Test("passing nil clears all four columns")
  func clearWipesAll() async throws {
    let trip = try await database.write { db -> Trip in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      try Trip.setHeaderImage(
        TripHeaderImage(url: "https://images.unsplash.com/photo-1.jpg", color: "#000"),
        tripID: trip.id, in: db
      )
      try Trip.setHeaderImage(nil, tripID: trip.id, in: db)
      return try Trip.find(trip.id).fetchOne(db)!
    }
    #expect(trip.headerImage == nil)
    #expect(trip.headerImageURL == nil)
    #expect(trip.headerImageColor == nil)
    #expect(trip.headerPhotographerName == nil)
    #expect(trip.headerPhotographerUsername == nil)
  }

  @Test("headerImage is nil whenever the URL is absent, even if stray fields linger")
  func urlGovernsPresence() {
    var trip = Trip(id: UUID())
    trip.headerPhotographerName = "orphan"
    #expect(trip.headerImage == nil)
  }
}
