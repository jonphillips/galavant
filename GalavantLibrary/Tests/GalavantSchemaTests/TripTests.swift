import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import IssueReporting
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripTests {
  @Dependency(\.defaultDatabase) var database

  // MARK: - Certainty round-trips (pure)

  @Test func certaintyRoundTripsThroughColumns() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let cases: [Certainty] = [
      .someday(rank: 3),
      .targeted(year: 2027, quarter: .q2),
      .targeted(year: 2028, quarter: nil),
      .dated(start: date),
    ]
    for certainty in cases {
      var trip = Trip(id: UUID())
      trip.apply(certainty)
      #expect(trip.certainty == certainty)
    }
  }

  @Test func applyClearsColumnsTheStageDoesntUse() {
    var trip = Trip(id: UUID())
    trip.apply(.targeted(year: 2027, quarter: .q3))
    trip.apply(.someday(rank: 5))
    #expect(trip.targetYear == nil)
    #expect(trip.targetQuarter == nil)
    #expect(trip.startDate == nil)
    #expect(trip.somedayRank == 5)
  }

  @Test func degenerateStoredStateFallsBackToSomeday() {
    withKnownIssue {
      let certainty = Certainty(
        stage: .targeted, somedayRank: 2, targetYear: nil, targetQuarter: nil, startDate: nil
      )
      #expect(certainty == .someday(rank: 2))
    }
  }

  // MARK: - Pure sectioning

  @Test func sectionedOrdersEachStage() {
    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let late = Date(timeIntervalSince1970: 1_800_000_000)
    let trips = [
      trip("Backlog B", .someday(rank: 1)),
      trip("Backlog A", .someday(rank: 0)),
      trip("Later Year", .targeted(year: 2028, quarter: .q1)),
      trip("Same Year Q3", .targeted(year: 2027, quarter: .q3)),
      trip("Same Year Q1", .targeted(year: 2027, quarter: .q1)),
      trip("Departs late", .dated(start: late)),
      trip("Departs early", .dated(start: early)),
    ]
    let sections = Trip.sectioned(trips)
    #expect(sections.someday.map(\.name) == ["Backlog A", "Backlog B"])
    #expect(sections.targeted.map(\.name) == ["Same Year Q1", "Same Year Q3", "Later Year"])
    #expect(sections.dated.map(\.name) == ["Departs early", "Departs late"])
  }

  // MARK: - Persistence

  @Test func createAppendsSomedayToBottomOfBacklog() async throws {
    let ranks = try await database.write { db -> [Int] in
      let first = try Trip.create(name: "Denmark", in: db)
      let second = try Trip.create(name: "Japan", in: db)
      let third = try Trip.create(name: "Italy", in: db)
      return [first, second, third].map(\.somedayRank)
    }
    #expect(ranks == [0, 1, 2])
  }

  @Test func createTargetedAndDatedSetTheRightColumns() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let (targeted, dated) = try await database.write { db -> (Trip, Trip) in
      let t = try Trip.create(
        name: "Spain", certainty: .targeted(year: 2027, quarter: .q2), lengthInDays: 10, in: db
      )
      let d = try Trip.create(
        name: "Copenhagen", certainty: .dated(start: start), lengthInDays: 9, in: db
      )
      return (t, d)
    }
    #expect(targeted.certainty == .targeted(year: 2027, quarter: .q2))
    #expect(targeted.lengthInDays == 10)
    #expect(dated.certainty == .dated(start: start))
    #expect(dated.lengthInDays == 9)
  }

  @Test func reorderSomedayPersistsNewRanks() async throws {
    let reordered = try await database.write { db -> [String] in
      let a = try Trip.create(name: "A", in: db)
      let b = try Trip.create(name: "B", in: db)
      let c = try Trip.create(name: "C", in: db)
      try Trip.reorderSomeday([c.id, a.id, b.id], in: db)
      return Trip.sectioned(try Trip.all.fetchAll(db)).someday.map(\.name)
    }
    #expect(reordered == ["C", "A", "B"])
  }

  @Test func updatePreservesSomedayRankWhenStayingInBacklog() async throws {
    let rank = try await database.write { db -> Int in
      let trip = try Trip.create(name: "First", in: db)
      _ = try Trip.create(name: "Second", in: db)
      var draft = Trip.Draft(trip)
      draft.name = "First (renamed)"
      try Trip.update(draft, certainty: .someday(rank: trip.somedayRank), in: db)
      return try Trip.find(trip.id).fetchOne(db)!.somedayRank
    }
    #expect(rank == 0)
  }

  @Test func updateMovingIntoSomedayAppendsToBottom() async throws {
    let rank = try await database.write { db -> Int in
      _ = try Trip.create(name: "Backlog 0", in: db)
      _ = try Trip.create(name: "Backlog 1", in: db)
      let targeted = try Trip.create(
        name: "Spain", certainty: .targeted(year: 2027, quarter: .q2), in: db
      )
      var draft = Trip.Draft(targeted)
      try Trip.update(draft, certainty: .someday(rank: 0), in: db)
      return try Trip.find(targeted.id).fetchOne(db)!.somedayRank
    }
    #expect(rank == 2)
  }

  // MARK: - TripIdea lifecycle (ADR-0004)

  @Test func pullIsIdempotent() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Tivoli", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    #expect(count == 1)
  }

  @Test func statusAdvancesThroughLifecycle() async throws {
    let status = try await database.write { db -> TripIdeaStatus? in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      #expect(pulled.status == .considering)
      try TripIdea.setStatus(.shortlisted, ideaID: idea.id, tripID: trip.id, in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)?.status
    }
    #expect(status == .shortlisted)
    #expect(status?.isOnShortlist == true)
  }

  @Test func removeTakesIdeaOffTheTrip() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Strøget", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.remove(ideaID: idea.id, from: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    #expect(count == 0)
  }

  @Test func deletingTripCascadesItsTripIdeas() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Nyhavn", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try Trip.find(trip.id).delete().execute(db)
      return try TripIdea.all.fetchCount(db)
    }
    #expect(count == 0)
  }

  // MARK: - Shortlist ranking (M3b)

  @Test func promotingToShortlistAppendsRanks() async throws {
    let ranks = try await database.write { db -> [Int] in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let a = try seedIdea(name: "Tivoli", in: db)
      let b = try seedIdea(name: "Noma", in: db)
      try TripIdea.pull(ideaID: a.id, into: trip.id, in: db)
      try TripIdea.pull(ideaID: b.id, into: trip.id, in: db)
      try TripIdea.setStatus(.shortlisted, ideaID: a.id, tripID: trip.id, in: db)
      try TripIdea.setStatus(.shortlisted, ideaID: b.id, tripID: trip.id, in: db)
      let entries = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      return TripIdea.shortlist(entries).map(\.shortlistRank)
    }
    #expect(ranks == [0, 1])
  }

  @Test func reorderShortlistPersistsOrder() async throws {
    let order = try await database.write { db -> [String] in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let ideas = try ["A", "B", "C"].map { try seedIdea(name: $0, in: db) }
      for idea in ideas {
        try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: idea.id, tripID: trip.id, in: db)
      }
      let entries = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let joinID = Dictionary(uniqueKeysWithValues: entries.map { ($0.ideaID, $0.id) })
      try TripIdea.reorderShortlist(
        [joinID[ideas[2].id]!, joinID[ideas[0].id]!, joinID[ideas[1].id]!], in: db
      )
      let names = Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0.name) })
      let reordered = TripIdea.shortlist(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db))
      return reordered.map { names[$0.ideaID]! }
    }
    #expect(order == ["C", "A", "B"])
  }

  @Test func shortlistAndConsideringPartition() {
    let trip = UUID()
    let entries = [
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .considering),
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .shortlisted, shortlistRank: 1),
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .scheduled, shortlistRank: 0),
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .skipped),
    ]
    #expect(TripIdea.considering(entries).count == 1)
    // scheduled (rank 0) and shortlisted (rank 1) are on the shortlist, in rank
    // order; considering and skipped are excluded.
    #expect(TripIdea.shortlist(entries).map(\.shortlistRank) == [0, 1])
  }

  // MARK: - Helpers

  private func trip(_ name: String, _ certainty: Certainty) -> Trip {
    var trip = Trip(id: UUID(), name: name)
    trip.apply(certainty)
    return trip
  }

  private func seedIdea(name: String, in db: Database) throws -> Idea {
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert { Idea.Draft(id: id, name: name, travelPartyID: partyID) }.execute(db)
    return try Idea.find(id).fetchOne(db)!
  }
}
