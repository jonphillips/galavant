import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

// `Testing` also exports a `Tag` type; disambiguate to ours in this file.
private typealias Tag = GalavantSchema.Tag

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TagTests {
  @Dependency(\.defaultDatabase) var database

  @Test func findOrCreateReusesCaseInsensitively() async throws {
    try await database.write { db in
      let a = try Tag.findOrCreate(named: "Michelin", in: db)
      let b = try Tag.findOrCreate(named: "michelin", in: db)
      #expect(a.id == b.id)
    }
    let count = try await database.read { db in try Tag.all.fetchCount(db) }
    #expect(count == 1)
  }

  @Test func addAndRemoveTagsOnIdea() async throws {
    let (ideaID, michelinID) = try await database.write { db -> (Idea.ID, Tag.ID) in
      let idea = try seedIdea("Noma", in: db)
      let michelin = try Tag.findOrCreate(named: "Michelin", in: db)
      let kidFriendly = try Tag.findOrCreate(named: "kid-friendly", in: db)
      try IdeaTag.add(tagID: michelin.id, to: idea.id, in: db)
      try IdeaTag.add(tagID: michelin.id, to: idea.id, in: db)  // dup ignored
      try IdeaTag.add(tagID: kidFriendly.id, to: idea.id, in: db)
      try IdeaTag.remove(tagID: kidFriendly.id, from: idea.id, in: db)
      return (idea.id, michelin.id)
    }
    let tagIDs = try await database.read { db in
      try IdeaTag.where { $0.ideaID.eq(ideaID) }.fetchAll(db).map(\.tagID)
    }
    #expect(tagIDs == [michelinID])
  }

  @Test func saveUpsertsIdeaAndReconcilesTags() async throws {
    // First save: new idea (nil draft id) with two tags.
    let id = try await database.write { db in
      try Idea.save(
        Idea.Draft(name: "Noma"), tagNames: ["Michelin", "kid-friendly"], in: db
      )
    }
    let afterFirst = try await database.read { db in
      try (
        idea: Idea.find(id).fetchOne(db),
        count: Idea.all.fetchCount(db),
        tags: tagNames(forIdea: id, in: db)
      )
    }
    #expect(afterFirst.idea?.travelPartyID != nil)  // party resolved
    #expect(afterFirst.tags == ["Michelin", "kid-friendly"])

    // Second save: same id, swapped tag set — drop Michelin, keep kid-friendly, add outdoor.
    try await database.write { db in
      try Idea.save(
        Idea.Draft(id: id, name: "Noma"), tagNames: ["kid-friendly", "outdoor"], in: db
      )
    }
    let afterSecond = try await database.read { db in
      try (count: Idea.all.fetchCount(db), tags: tagNames(forIdea: id, in: db))
    }
    #expect(afterSecond.count == 1)  // upsert, not a duplicate row
    #expect(afterSecond.tags == ["kid-friendly", "outdoor"])  // reconciled exactly
  }

  @Test func tagFilterRequiresAllSelectedTags() {
    let noma = idea("Noma")
    let cafe = idea("Cafe")
    let michelin = UUID(), outdoor = UUID()
    let ideaTagIDs: [Idea.ID: Set<Tag.ID>] = [
      noma.id: [michelin, outdoor],
      cafe.id: [outdoor],
    ]
    // Selecting Michelin keeps only Noma.
    let result = poolFiltered(
      [noma, cafe], tagIDs: [michelin], ideaTagIDs: ideaTagIDs
    )
    #expect(result.map(\.name) == ["Noma"])
    // Selecting Michelin + outdoor still only Noma (cafe lacks Michelin).
    let both = poolFiltered(
      [noma, cafe], tagIDs: [michelin, outdoor], ideaTagIDs: ideaTagIDs
    )
    #expect(both.map(\.name) == ["Noma"])
  }

  private func seedIdea(_ name: String, in db: Database) throws -> Idea {
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert { Idea.Draft(id: id, name: name, travelPartyID: partyID) }.execute(db)
    return try Idea.find(id).fetchOne(db)!
  }

  private func idea(_ name: String) -> Idea { Idea(id: UUID(), name: name) }

  private func tagNames(forIdea id: Idea.ID, in db: Database) throws -> [String] {
    try IdeaTag.where { $0.ideaID.eq(id) }.fetchAll(db)
      .compactMap { try Tag.find($0.tagID).fetchOne(db)?.name }
      .sorted()
  }
}
