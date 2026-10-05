import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies {
  try $0.bootstrapDatabase()
  $0.uuid = .incrementing
  $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
})
struct TripDocumentTests {
  @Dependency(\.defaultDatabase) var database

  @Test func addRenameDeleteAndNewestFirstOrdering() async throws {
    let (firstID, secondID) = try await database.write { db -> (UUID, UUID) in
      let trip = try Trip.create(name: "Denmark", in: db)
      let firstID = try TripDocument.add(
        tripID: trip.id, title: "  ", body: "first", origin: .pasted,
        now: Date(timeIntervalSince1970: 1_700_000_000), in: db)
      let secondID = try TripDocument.add(
        tripID: trip.id, title: "Later", body: "second", origin: .pasted,
        now: Date(timeIntervalSince1970: 1_700_000_100), in: db)
      #expect(
        try TripDocument.where { $0.tripID.eq(trip.id) }
          .order { ($0.createdAt.desc(), $0.id) }
          .fetchAll(db).map(\.id) == [secondID, firstID]
      )
      #expect(try TripDocument.find(firstID).fetchOne(db)?.title.hasPrefix("Document — ") == true)
      try TripDocument.rename(secondID, title: "Renamed", in: db)
      #expect(try TripDocument.find(secondID).fetchOne(db)?.title == "Renamed")
      try TripDocument.delete(firstID, in: db)
      #expect(try TripDocument.find(firstID).fetchOne(db) == nil)
      return (firstID, secondID)
    }
    #expect(firstID != secondID)
  }

  @Test func validatesBodySizeAndContent() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      #expect(throws: TripDocumentError.emptyBody) {
        try TripDocument.add(tripID: trip.id, title: "Empty", body: " \n ", origin: .pasted, in: db)
      }
      #expect(throws: TripDocumentError.tooLarge) {
        try TripDocument.add(
          tripID: trip.id, title: "Large", body: String(repeating: "a", count: 512_001),
          origin: .pasted, in: db)
      }
    }
  }

  @Test func deletingTripCascadesDocuments() async throws {
    let documentID = try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let id = try TripDocument.add(
        tripID: trip.id, title: "Research", body: "notes", origin: .pasted, in: db)
      try Trip.find(trip.id).delete().execute(db)
      return id
    }
    let document = try await database.read { db in try TripDocument.find(documentID).fetchOne(db) }
    #expect(document == nil)
  }
}
