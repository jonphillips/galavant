import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct IdeaTests {
  @Dependency(\.defaultDatabase) var database

  @Test func roundTrip() async throws {
    try await database.write { db in
      try Idea.insert {
        Idea.Draft(name: "Tivoli Gardens", notes: "Evening illuminations", regionName: "Copenhagen")
      }
      .execute(db)
    }
    let ideas = try await database.read { db in
      try Idea.order(by: \.name).fetchAll(db)
    }
    #expect(ideas.count == 1)
    #expect(ideas.first?.name == "Tivoli Gardens")
    #expect(ideas.first?.regionName == "Copenhagen")
  }

  @Test func upsertEditsExistingIdea() async throws {
    try await database.write { db in
      try Idea.insert {
        Idea.Draft(name: "Noma")
      }
      .execute(db)
    }
    let saved = try await database.read { db in
      try Idea.order(by: \.name).fetchAll(db)
    }
    let noma = try #require(saved.first)
    try await database.write { db in
      var draft = Idea.Draft(noma)
      draft.notes = "Book when window opens"
      try Idea.upsert { draft }.execute(db)
    }
    let ideas = try await database.read { db in
      try Idea.order(by: \.name).fetchAll(db)
    }
    #expect(ideas.count == 1)
    #expect(ideas.first?.notes == "Book when window opens")
  }

  @Test("supplemented fills only blank facts and back-fills a missing map identity")
  func supplementedFillsBlanksOnly() {
    let existing = Idea(id: UUID(), name: "Noma", kind: .food, url: "https://noma.dk")
    let merged = existing.supplemented(
      name: "Different Name", kind: .drink, regionName: "Copenhagen",
      address: "Refshalevej 96", phone: "+4500", latitude: 55.6839, longitude: 12.6109,
      url: "https://other.example", mapItemIdentifier: "maps:noma-cph"
    )
    // Present values stand — a deliberate edit / structured fact is never clobbered.
    #expect(merged.name == "Noma")
    #expect(merged.kind == .food)
    #expect(merged.url == "https://noma.dk")
    // Blanks are filled from the new capture.
    #expect(merged.regionName == "Copenhagen")
    #expect(merged.address == "Refshalevej 96")
    #expect(merged.phone == "+4500")
    #expect(merged.latitude == 55.6839)
    #expect(merged.longitude == 12.6109)
    #expect(merged.mapItemIdentifier == "maps:noma-cph")
  }

  @Test("supplemented never overwrites an existing map identity")
  func supplementedKeepsExistingIdentity() {
    let existing = Idea(id: UUID(), name: "Noma", mapItemIdentifier: "maps:original")
    let merged = existing.supplemented(
      name: "Noma", kind: nil, regionName: nil, address: nil, phone: nil,
      latitude: nil, longitude: nil, url: "", mapItemIdentifier: "maps:different"
    )
    #expect(merged.mapItemIdentifier == "maps:original")
  }
}
