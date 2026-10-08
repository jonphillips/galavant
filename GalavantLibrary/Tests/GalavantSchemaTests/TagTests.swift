import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

// `Testing` also exports a `Tag` type; disambiguate to ours in this file.
private typealias Tag = GalavantSchema.Tag

@Suite(.serialized, .dependencies { try $0.bootstrapDatabase() })
struct TagTests {
  @Dependency(\.defaultDatabase) var database

  @Test func findOrCreateReusesCaseInsensitively() async throws {
    try await database.write { db in
      let a = try Tag.findOrCreate(named: "FindReuse-Michelin", in: db)
      let b = try Tag.findOrCreate(named: "findreuse-michelin", in: db)
      #expect(a.id == b.id)
    }
    let count = try await database.read { db in
      try Tag.all.fetchAll(db).filter { $0.name.caseInsensitiveCompare("FindReuse-Michelin") == .orderedSame }.count
    }
    #expect(count == 1)
  }

  @Test func addAndRemoveTagsOnIdea() async throws {
    let (ideaID, michelinID) = try await database.write { db -> (Idea.ID, Tag.ID) in
      let idea = try seedIdea("Noma", in: db)
      let michelin = try Tag.findOrCreate(named: "AddRemove-Michelin", in: db)
      let kidFriendly = try Tag.findOrCreate(named: "AddRemove-kid-friendly", in: db)
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
        Idea.Draft(name: "Noma"), tagNames: ["Save-Michelin", "Save-kid-friendly"], in: db
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
    #expect(afterFirst.tags == ["Save-Michelin", "Save-kid-friendly"])

    // Second save: same id, swapped tag set — drop Michelin, keep kid-friendly, add outdoor.
    _ = try await database.write { db in
      try Idea.save(
        Idea.Draft(id: id, name: "Noma"), tagNames: ["Save-kid-friendly", "Save-outdoor"], in: db
      )
    }
    let afterSecond = try await database.read { db in
      try (count: Idea.all.fetchCount(db), tags: tagNames(forIdea: id, in: db))
    }
    #expect(afterSecond.count == 1)  // upsert, not a duplicate row
    #expect(afterSecond.tags == ["Save-kid-friendly", "Save-outdoor"])  // reconciled exactly
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

  @Test func convergenceRepointsJoinsAndIsIdempotent() async throws {
    let (lower, higher) = orderedUUIDs()
    let result = try await database.write { db -> (Tag.ID, Set<Idea.ID>) in
      let partyID = try TravelParty.ensureDefault(in: db).id
      let a = try seedIdea("A", in: db)
      let b = try seedIdea("B", in: db)
      let c = try seedIdea("C", in: db)
      let name = "Converge-\(UUID().uuidString)"
      try Tag.insert {
        Tag.Draft(Tag(id: higher, name: name, travelPartyID: partyID))
      }.execute(db)
      try Tag.insert {
        Tag.Draft(Tag(id: lower, name: " \(name.lowercased()) ", travelPartyID: partyID))
      }.execute(db)
      try IdeaTag.add(tagID: higher, to: a.id, in: db)
      try IdeaTag.add(tagID: higher, to: b.id, in: db)
      try IdeaTag.add(tagID: lower, to: b.id, in: db)
      try IdeaTag.add(tagID: lower, to: c.id, in: db)
      _ = try Tag.convergeDuplicates(in: db)
      let rows = try IdeaTag.where { $0.ideaID.in([a.id, b.id, c.id]) }.fetchAll(db)
      #expect(rows.count == 3)
      #expect(Set(rows.map(\.tagID)) == [lower])
      #expect(Set(rows.map(\.ideaID)) == [a.id, b.id, c.id])
      let before = try (Tag.all.fetchAll(db), IdeaTag.all.fetchAll(db))
      _ = try Tag.convergeDuplicates(in: db)
      let after = try (Tag.all.fetchAll(db), IdeaTag.all.fetchAll(db))
      #expect(before.0 == after.0)
      #expect(before.1 == after.1)
      return (lower, Set(rows.map(\.ideaID)))
    }
    #expect(result.0 == lower)
    #expect(result.1.count == 3)
  }

  @Test func findOrCreateConvergesAndReturnsLowestID() async throws {
    let (lower, higher) = orderedUUIDs()
    let name = "FindOrCreate-\(UUID().uuidString)"
    let returned = try await database.write { db in
      let partyID = try TravelParty.ensureDefault(in: db).id
      try Tag.insert { Tag.Draft(Tag(id: higher, name: name.uppercased(), travelPartyID: partyID)) }.execute(db)
      try Tag.insert { Tag.Draft(Tag(id: lower, name: name, travelPartyID: partyID)) }.execute(db)
      return try Tag.findOrCreate(named: " \(name.lowercased()) ", in: db)
    }
    #expect(returned.id == lower)
    let count = try await database.read { db in
      try Tag.all.fetchAll(db).filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.count
    }
    #expect(count == 1)
  }

  @Test(arguments: [true, false])
  func renameCollisionKeepsLowestIDAndAllIdeas(renamedTagHasLowerID: Bool) async throws {
    let (low, high) = orderedUUIDs()
    let newName = "Rename-\(UUID().uuidString)"
    let outcome = try await database.write { db -> (Tag.ID, [String], Int) in
      let partyID = try TravelParty.ensureDefault(in: db).id
      let renamedID = renamedTagHasLowerID ? low : high
      let existingID = renamedTagHasLowerID ? high : low
      try Tag.insert { Tag.Draft(Tag(id: renamedID, name: "Old-\(newName)", travelPartyID: partyID)) }.execute(db)
      try Tag.insert { Tag.Draft(Tag(id: existingID, name: newName, travelPartyID: partyID)) }.execute(db)
      let a = try seedIdea("A", in: db)
      let b = try seedIdea("B", in: db)
      try IdeaTag.add(tagID: renamedID, to: a.id, in: db)
      try IdeaTag.add(tagID: existingID, to: b.id, in: db)
      let result = try Tag.rename(renamedID, to: newName.uppercased(), in: db)!
      return (result.id, try tagNames(forIdea: a.id, in: db) + tagNames(forIdea: b.id, in: db), try IdeaTag.all.fetchCount(db))
    }
    #expect(outcome.0 == low)
    #expect(outcome.1 == [newName.uppercased(), newName.uppercased()])
    #expect(outcome.2 == 2)
  }

  @Test func deletesRemoveJoinsAndUnusedTags() async throws {
    let counts = try await database.write { db -> (Int, Int, Bool, Int, Int) in
      let used = try Tag.findOrCreate(named: "DeleteUsed-\(UUID())", in: db)
      let unused = try Tag.findOrCreate(named: "DeleteUnused-\(UUID())", in: db)
      let idea = try seedIdea("A", in: db)
      try IdeaTag.add(tagID: used.id, to: idea.id, in: db)
      let usedIDs = Set(try IdeaTag.all.fetchAll(db).map(\.tagID))
      let expectedUnused = try Tag.all.fetchAll(db).filter { !usedIDs.contains($0.id) }.count
      let removedUnused = try Tag.deleteUnused(in: db)
      let usedSurvivedCleanup = try Tag.find(used.id).fetchOne(db) != nil
      try Tag.delete([used.id], in: db)
      let unusedStillExists = try Tag.find(unused.id).fetchOne(db) != nil
      let usedStillExists = try Tag.find(used.id).fetchOne(db) != nil
      let staleJoins = try IdeaTag.where { $0.tagID.in([used.id, unused.id]) }.fetchCount(db)
      return (
        removedUnused,
        expectedUnused,
        usedSurvivedCleanup,
        (unusedStillExists ? 1 : 0) + (usedStillExists ? 1 : 0),
        staleJoins
      )
    }
    #expect(counts.0 == counts.1)
    #expect(counts.2)
    #expect(counts.3 == 0)
    #expect(counts.4 == 0)
  }

  @Test func tagIndexProjectsCountsNamesDuplicatesAndOrphans() {
    let partyID = UUID()
    let ideaA = UUID(), ideaB = UUID()
    let low = Tag(id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!, name: "Food", travelPartyID: partyID)
    let duplicate = Tag(id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!, name: " food ", travelPartyID: partyID)
    let stay = Tag(id: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!, name: "Stay", travelPartyID: partyID)
    let orphan = UUID()
    let joins = [
      IdeaTag(id: UUID(), ideaID: ideaA, tagID: low.id),
      IdeaTag(id: UUID(), ideaID: ideaA, tagID: duplicate.id),
      IdeaTag(id: UUID(), ideaID: ideaA, tagID: stay.id),
      IdeaTag(id: UUID(), ideaID: ideaB, tagID: low.id),
      IdeaTag(id: UUID(), ideaID: ideaB, tagID: orphan),
    ]
    let index = TagIndex(tags: [duplicate, stay, low], ideaTags: joins)
    #expect(index.tags.map(\.id) == [low.id, stay.id])
    #expect(index.useCount(for: low.id) == 2)
    #expect(index.names(for: ideaA) == ["Food", "Stay"])
    #expect(index.names(for: ideaB) == ["Food"])
    #expect(index.effectiveSelection([duplicate.id, orphan]) == [low.id])
  }

  @Test func missingSelectedTagDoesNotFilterPool() {
    let noma = idea("Noma")
    let index = TagIndex(tags: [], ideaTags: [])
    #expect(poolFiltered([noma], tagIDs: index.effectiveSelection([UUID()])) == [noma])
  }

  private func seedIdea(_ name: String, in db: Database) throws -> Idea {
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert { Idea.Draft(id: id, name: name, travelPartyID: partyID) }.execute(db)
    return try Idea.find(id).fetchOne(db)!
  }

  private func idea(_ name: String) -> Idea { Idea(id: UUID(), name: name) }

  private func orderedUUIDs() -> (UUID, UUID) {
    let values = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
    return (values[0], values[1])
  }

  private func tagNames(forIdea id: Idea.ID, in db: Database) throws -> [String] {
    try IdeaTag.where { $0.ideaID.eq(id) }.fetchAll(db)
      .compactMap { try Tag.find($0.tagID).fetchOne(db)?.name }
      .sorted()
  }
}
