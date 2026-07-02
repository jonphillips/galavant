import Dependencies
import DependenciesTestSupport
import Foundation
import LLMClientKit
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantChat

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct ChatToolsTests {
  @Dependency(\.defaultDatabase) var database

  @Test func parseKindAcceptsRawValueAndLabel() {
    #expect(PoolToolExecutor.parseKind("food") == .food)
    #expect(PoolToolExecutor.parseKind("Food") == .food)
    #expect(PoolToolExecutor.parseKind("Museum") == .museum)
    #expect(PoolToolExecutor.parseKind("nonsense") == nil)
  }

  @Test func queryPoolFiltersByKindAndVisited() async throws {
    try await database.write { db in
      _ = try seed(name: "Noma", kind: .food, region: "Copenhagen", visited: false, in: db)
      _ = try seed(name: "Geranium", kind: .food, region: "Copenhagen", visited: true, in: db)
      _ = try seed(name: "Tivoli", kind: .activity, region: "Copenhagen", visited: false, in: db)
    }
    let executor = PoolToolExecutor()

    let foodUnvisited = await executor.run(
      call("query_pool", ["kind": "food", "includeVisited": .bool(false)]))
    #expect(foodUnvisited.contains("Noma"))
    #expect(!foodUnvisited.contains("Geranium"))  // visited, excluded
    #expect(!foodUnvisited.contains("Tivoli"))  // wrong kind

    let allFood = await executor.run(call("query_pool", ["kind": "food"]))
    #expect(allFood.contains("Noma"))
    #expect(allFood.contains("Geranium"))  // visited included by default
  }

  @Test func queryPoolMatchesFreeTextAndRegion() async throws {
    try await database.write { db in
      _ = try seed(name: "Noma", kind: .food, region: "Copenhagen", visited: false, in: db)
      _ = try seed(name: "Pujol", kind: .food, region: "Mexico City", visited: false, in: db)
    }
    let executor = PoolToolExecutor()

    let byRegion = await executor.run(call("query_pool", ["region": "mexico"]))
    #expect(byRegion.contains("Pujol"))
    #expect(!byRegion.contains("Noma"))

    let noMatch = await executor.run(call("query_pool", ["query": "zzzznope"]))
    #expect(noMatch.contains("No ideas match"))
  }

  @Test func createIdeaLandsACandidateInThePool() async throws {
    let executor = PoolToolExecutor()
    let result = await executor.run(
      call("create_idea", ["name": "Alchemist", "kind": "food", "region": "Copenhagen"]))
    #expect(result.contains("Alchemist"))
    #expect(result.contains("candidate"))

    let stored = try await database.read { db in
      try Idea.where { $0.name.eq("Alchemist") }.fetchAll(db)
    }
    #expect(stored.count == 1)
    #expect(stored.first?.kind == .food)
    #expect(stored.first?.regionName == "Copenhagen")
    // A candidate is a pool idea not pulled onto any trip.
    let pulls = try await database.read { db in try TripIdea.all.fetchAll(db) }
    #expect(pulls.isEmpty)
  }

  @Test func createIdeaRequiresAName() async {
    let result = await PoolToolExecutor().run(call("create_idea", ["notes": "no name here"]))
    #expect(result.contains("name is required"))
  }

  // MARK: - Helpers

  private func call(_ name: String, _ input: JSONValue) -> ModelToolCall {
    ModelToolCall(id: "toolu_\(name)", name: name, input: input)
  }

  private func seed(
    name: String, kind: IdeaKind, region: String, visited: Bool, in db: Database
  ) throws -> Idea {
    let travelPartyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert {
      Idea.Draft(
        id: id, name: name, kind: kind, regionName: region, visited: visited,
        travelPartyID: travelPartyID)
    }
    .execute(db)
    return try Idea.find(id).fetchOne(db)!
  }
}
