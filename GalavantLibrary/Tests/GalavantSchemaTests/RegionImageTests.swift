import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct RegionImageTests {
  @Dependency(\.defaultDatabase) var database

  @Test("A region holds at most one photo — a re-pick replaces it")
  func setReplaces() async throws {
    let regionID = try await database.write { db -> MapRegion.ID in
      let region = try seedRegion("Bavaria", in: db)
      try RegionImage.set(
        regionID: region.id, display: bytes("a"), thumbnail: bytes("at"),
        sourceURL: "https://unsplash.com/a.jpg", photographerName: "Ansel",
        photographerUsername: "ansel", id: UUID(), in: db)
      try RegionImage.set(
        regionID: region.id, display: bytes("b"), thumbnail: bytes("bt"),
        sourceURL: nil, id: UUID(), in: db)
      return region.id
    }
    let stored = try await database.read { db in
      try RegionImage.where { $0.regionID.eq(regionID) }.fetchAll(db)
    }
    #expect(stored.count == 1)
    #expect(stored.first?.display == bytes("b"))
    #expect(stored.first?.sourceURL == nil)  // the Photos re-pick cleared attribution
    #expect(stored.first?.photographerName == nil)
  }

  @Test("image(forRegion:) returns the stored photo, clear removes it")
  func fetchAndClear() async throws {
    let regionID = try await database.write { db -> MapRegion.ID in
      let region = try seedRegion("Dolomites", in: db)
      try RegionImage.set(
        regionID: region.id, display: bytes("x"), thumbnail: bytes("xt"),
        id: UUID(), in: db)
      return region.id
    }
    let fetched = try await database.read { db in
      try RegionImage.image(forRegion: regionID, in: db)
    }
    #expect(fetched?.thumbnail == bytes("xt"))

    try await database.write { db in
      try RegionImage.clear(forRegion: regionID, in: db)
    }
    let after = try await database.read { db in
      try RegionImage.image(forRegion: regionID, in: db)
    }
    #expect(after == nil)
  }

  @Test("Deleting a region cascade-deletes its photo")
  func cascadeDelete() async throws {
    let regionID = try await database.write { db -> MapRegion.ID in
      let region = try seedRegion("Tuscany", in: db)
      try RegionImage.set(
        regionID: region.id, display: bytes("a"), thumbnail: bytes("at"),
        id: UUID(), in: db)
      return region.id
    }
    try await database.write { db in
      try MapRegion.where { $0.id.eq(regionID) }.delete().execute(db)
    }
    let remaining = try await database.read { db in
      try RegionImage.where { $0.regionID.eq(regionID) }.fetchCount(db)
    }
    #expect(remaining == 0)
  }

  private func seedRegion(_ name: String, in db: Database) throws -> MapRegion {
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try MapRegion.insert {
      MapRegion.Draft(
        MapRegion(
          id: id, name: name, centerLatitude: 47, centerLongitude: 11,
          latitudeDelta: 2, longitudeDelta: 2, travelPartyID: partyID))
    }
    .execute(db)
    return try MapRegion.find(id).fetchOne(db)!
  }

  private func bytes(_ string: String) -> Data { Data(string.utf8) }
}
