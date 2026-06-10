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
}
