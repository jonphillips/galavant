import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct ImageAssetTests {
  @Dependency(\.defaultDatabase) var database

  @Test("First stored image becomes the header; the rest follow by rank")
  func firstImageIsHeader() async throws {
    let ideaID = try await database.write { db -> Idea.ID in
      let idea = try seedIdea("Noma", in: db)
      try ImageAsset.store(
        ideaID: idea.id, display: bytes("a"), thumbnail: bytes("at"),
        sourceURL: "https://noma.dk/1.jpg", id: UUID(), in: db
      )
      try ImageAsset.store(
        ideaID: idea.id, display: bytes("b"), thumbnail: bytes("bt"),
        sourceURL: "https://noma.dk/2.jpg", id: UUID(), in: db
      )
      return idea.id
    }
    let images = try await database.read { db in
      try ImageAsset.images(forIdea: ideaID, in: db)
    }
    #expect(images.count == 2)
    #expect(images.first?.sourceURL == "https://noma.dk/1.jpg")
    #expect(images.first?.isHeader == true)
    #expect(images.dropFirst().allSatisfy { !$0.isHeader })
  }

  @Test("Storing the same source URL again updates bytes, not a duplicate row")
  func idempotentOnSourceURL() async throws {
    let ideaID = try await database.write { db -> Idea.ID in
      let idea = try seedIdea("Noma", in: db)
      try ImageAsset.store(
        ideaID: idea.id, display: bytes("old"), thumbnail: bytes("oldt"),
        sourceURL: "https://noma.dk/hero.jpg", id: UUID(), in: db
      )
      try ImageAsset.store(
        ideaID: idea.id, display: bytes("new"), thumbnail: bytes("newt"),
        sourceURL: "https://noma.dk/hero.jpg", id: UUID(), in: db
      )
      return idea.id
    }
    let images = try await database.read { db in
      try ImageAsset.images(forIdea: ideaID, in: db)
    }
    #expect(images.count == 1)
    #expect(images.first?.display == bytes("new"))
  }

  @Test("setHeader moves the flag to exactly one image")
  func setHeaderIsExclusive() async throws {
    let (ideaID, secondID) = try await database.write { db -> (Idea.ID, ImageAsset.ID) in
      let idea = try seedIdea("Noma", in: db)
      let first = try ImageAsset.store(
        ideaID: idea.id, display: bytes("a"), thumbnail: bytes("at"),
        sourceURL: "1.jpg", id: UUID(), in: db
      )
      let second = try ImageAsset.store(
        ideaID: idea.id, display: bytes("b"), thumbnail: bytes("bt"),
        sourceURL: "2.jpg", id: UUID(), in: db
      )
      #expect(first.isHeader)
      try ImageAsset.setHeader(second.id, ideaID: idea.id, in: db)
      return (idea.id, second.id)
    }
    let images = try await database.read { db in
      try ImageAsset.images(forIdea: ideaID, in: db)
    }
    #expect(images.filter(\.isHeader).count == 1)
    #expect(images.first?.id == secondID)  // header floats to front
  }

  @Test("Deleting an idea cascade-deletes its images")
  func cascadeDelete() async throws {
    let ideaID = try await database.write { db -> Idea.ID in
      let idea = try seedIdea("Noma", in: db)
      try ImageAsset.store(
        ideaID: idea.id, display: bytes("a"), thumbnail: bytes("at"),
        sourceURL: "1.jpg", id: UUID(), in: db
      )
      return idea.id
    }
    try await database.write { db in
      try Idea.where { $0.id.eq(ideaID) }.delete().execute(db)
    }
    let remaining = try await database.read { db in
      try ImageAsset.where { $0.ideaID.eq(ideaID) }.fetchCount(db)
    }
    #expect(remaining == 0)
  }

  private func seedIdea(_ name: String, in db: Database) throws -> Idea {
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert { Idea.Draft(id: id, name: name, travelPartyID: partyID) }.execute(db)
    return try Idea.find(id).fetchOne(db)!
  }

  private func bytes(_ string: String) -> Data { Data(string.utf8) }
}
