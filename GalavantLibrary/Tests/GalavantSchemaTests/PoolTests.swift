import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct PoolTests {
  @Dependency(\.defaultDatabase) var database

  @Test func hisAndHersRatings() async throws {
    try await database.write { db in
      let idea = try seedIdea(name: "Noma", kind: .food, in: db)
      let jon = try Planner.create(displayName: "Jon", in: db)
      let wife = try Planner.create(displayName: "Sam", in: db)
      try IdeaInterest.set(level: .mustDo, ideaID: idea.id, plannerID: jon.id, in: db)
      try IdeaInterest.set(level: .couldDo, ideaID: idea.id, plannerID: wife.id, in: db)
    }
    let ratings = try await database.read { db in
      try IdeaInterest.order(by: \.level).fetchAll(db)
    }
    #expect(ratings.count == 2)
    #expect(Set(ratings.compactMap(\.level)) == [.mustDo, .couldDo])
  }

  @Test func settingInterestAgainReplacesNotDuplicates() async throws {
    let (ideaID, plannerID) = try await database.write { db -> (Idea.ID, Planner.ID) in
      let idea = try seedIdea(name: "Tivoli", kind: .activity, in: db)
      let planner = try Planner.create(displayName: "Jon", in: db)
      try IdeaInterest.set(level: .wantToDo, ideaID: idea.id, plannerID: planner.id, in: db)
      try IdeaInterest.set(level: .mustDo, ideaID: idea.id, plannerID: planner.id, in: db)
      return (idea.id, planner.id)
    }
    let ratings = try await database.read { db in
      try IdeaInterest.where { $0.ideaID.eq(ideaID) && $0.plannerID.eq(plannerID) }.fetchAll(db)
    }
    #expect(ratings.count == 1)
    #expect(ratings.first?.level == .mustDo)
  }

  @Test func clearingInterestRemovesEmptyRow() async throws {
    let ideaID = try await database.write { db -> Idea.ID in
      let idea = try seedIdea(name: "Skagen", kind: .beach, in: db)
      let planner = try Planner.create(displayName: "Jon", in: db)
      try IdeaInterest.set(level: .couldDo, ideaID: idea.id, plannerID: planner.id, in: db)
      try IdeaInterest.set(level: nil, ideaID: idea.id, plannerID: planner.id, in: db)
      return idea.id
    }
    let count = try await database.read { db in
      try IdeaInterest.where { $0.ideaID.eq(ideaID) }.fetchCount(db)
    }
    #expect(count == 0)
  }

  private func seedIdea(name: String, kind: IdeaKind, in db: Database) throws -> Idea {
    let travelPartyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert {
      Idea.Draft(id: id, name: name, kind: kind, travelPartyID: travelPartyID)
    }
    .execute(db)
    return try Idea.find(id).fetchOne(db)!
  }
}
