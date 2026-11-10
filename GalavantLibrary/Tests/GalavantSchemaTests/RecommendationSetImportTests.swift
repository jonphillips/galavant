import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantAI
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies {
  try $0.bootstrapDatabase()
  $0.uuid = .incrementing
})
struct RecommendationSetImportTests {
  @Dependency(\.defaultDatabase) var database

  @Test func retryLinksExistingRowsAndKeepsNotes() throws {
    try database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let session = HandoffSession(sourceType: "trip", sourceID: trip.id, taskType: "candidatePlaces", exportedPrompt: "")
      let candidates = [TripCandidate(searchHint: "Museum", why: "A good fit")]
      let ideasBefore = try Idea.fetchCount(db)
      let first = try RecommendationSetImport.apply(candidates: candidates, note: "Notes", into: trip.id, session: session, now: .now, in: db)
      let retry = try RecommendationSetImport.apply(candidates: candidates, note: "Notes", into: trip.id, session: session, now: .now, in: db)
      let repeatImport = try RecommendationSetImport.apply(candidates: candidates, note: "Notes", into: trip.id, session: first.session, now: .now, in: db)
      #expect(repeatImport.session.candidateLinks.count == 1)
      let rows = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let documents = try TripDocument.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      #expect(rows.count == 1)
      #expect(rows[0].inlineTitle == "Museum")
      #expect(rows[0].rationaleWhy == "A good fit")
      #expect(rows[0].inlineNote == nil)
      #expect(rows[0].ideaID == nil)
      #expect(try Idea.fetchCount(db) == ideasBefore)
      #expect(documents.count == 1)
      #expect(first.session.candidateLinks.first?.tripIdeaID == retry.session.candidateLinks.first?.tripIdeaID)
      #expect(retry.remainingCount == 1)
    }
  }

  @Test func storesPriorityRanksAgainstTheRankedCandidatesAndLeavesThemIndependentOfShortlistOrder() throws {
    try database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let session = HandoffSession(sourceType: "trip", sourceID: trip.id, taskType: "candidatePlaces", exportedPrompt: "")
      let candidates = (1...5).map { (rank: Int) in
        TripCandidate(name: "Place \(rank)", priority: rank)
      }
      let result = try RecommendationSetImport.apply(
        candidates: candidates, note: nil, into: trip.id, session: session, now: .now, in: db)
      let rows = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db).sorted { $0.shortlistRank < $1.shortlistRank }
      #expect(rows.map(\.rationalePriority) == [1, 2, 3, 4, 5])
      #expect(rows.map(\.rationalePriorityOutOf) == [5, 5, 5, 5, 5])

      try TripIdea.reorderShortlist(rows.reversed().map(\.id), in: db)
      let reordered = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      #expect(Set(reordered.compactMap(\.rationalePriority)) == Set([1, 2, 3, 4, 5]))
      #expect(reordered.allSatisfy { $0.rationalePriorityOutOf == 5 })
      #expect(result.session.candidateLinks.count == 5)
    }
  }

  @Test func rankedRereturnUpdatesLinkedTripRowsAndClearsDroppedRanks() throws {
    try database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: "candidatePlaces", exportedPrompt: ""
      )
      let ranks: [Int] = [1, 2, 3, 4, 5]
      let first = try RecommendationSetImport.apply(
        candidates: ranks.map { rank -> TripCandidate in
          TripCandidate(name: "Place \(rank)", why: "Old \(rank)", priority: rank, list: "Old ranking")
        }, note: nil, into: trip.id, session: session, now: .now, in: db
      )
      let second = try RecommendationSetImport.apply(
        candidates: [
          TripCandidate(name: "Place 1", why: "Revised 1", priority: 2, list: "New ranking"),
          TripCandidate(name: "Place 2", why: "Revised 2", priority: 1, list: "New ranking"),
          TripCandidate(name: "Place 3", why: "Revised 3", priority: 3, list: "New ranking"),
          TripCandidate(name: "Place 6", why: "New six", priority: 4, list: "New ranking"),
        ], note: nil, into: trip.id, session: first.session, now: .now, in: db
      )

      let rows = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      #expect(second.session.candidateLinks.count == 6)
      #expect(rows.compactMap(\.inlineTitle).sorted() == ["Place 1", "Place 2", "Place 3", "Place 4", "Place 5", "Place 6"])
      #expect(rows.count == 6)
      let updated = ["Place 1": (2, "Revised 1"), "Place 2": (1, "Revised 2"),
        "Place 3": (3, "Revised 3"), "Place 6": (4, "New six")]
      for (name, values) in updated {
        let row = try #require(rows.first { $0.inlineTitle == name })
        #expect(row.rationaleWhy == values.1)
        #expect(row.rationalePriority == values.0)
        #expect(row.rationalePriorityOutOf == 4)
        #expect(row.rationalePriorityList == "New ranking")
      }
      for name in ["Place 4", "Place 5"] {
        let row = try #require(rows.first { $0.inlineTitle == name })
        #expect(row.rationalePriority == nil)
        #expect(row.rationalePriorityOutOf == nil)
        #expect(row.rationalePriorityList == nil)
      }
    }
  }

  @Test func choosesTheMostCommonListNameAndUsesDayScopeAsFallback() throws {
    try database.write { db in
      let trip = try Trip.create(name: "London", in: db)
      let session = HandoffSession(
        sourceType: "day", sourceID: trip.id, taskType: "candidatePlaces",
        scopeKey: "3", exportedPrompt: "")
      let candidates = [
        TripCandidate(name: "One", priority: 1, list: "Soho Indian"),
        TripCandidate(name: "Two", priority: 2, list: "Manchester hotels"),
        TripCandidate(name: "Three", priority: 3, list: "Soho Indian"),
      ]
      _ = try RecommendationSetImport.apply(
        candidates: candidates, note: nil, into: trip.id, session: session, now: .now, in: db)
      let rows = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      #expect(rows.allSatisfy { $0.rationalePriorityList == "Soho Indian" })

      let daySession = HandoffSession(
        sourceType: "day", sourceID: trip.id, taskType: "candidatePlaces",
        scopeKey: "3", exportedPrompt: "")
      _ = try RecommendationSetImport.apply(
        candidates: [TripCandidate(name: "Four", priority: 1)], note: nil,
        into: trip.id, session: daySession, now: .now, in: db)
      let fallback = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
        .first { $0.inlineTitle == "Four" }
      #expect(fallback?.rationalePriorityList == "Day 3")

      let tripSession = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: "candidatePlaces", exportedPrompt: "")
      _ = try RecommendationSetImport.apply(
        candidates: [TripCandidate(name: "Five", priority: 1)], note: nil,
        into: trip.id, session: tripSession, now: .now, in: db)
      let noFallback = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
        .first { $0.inlineTitle == "Five" }
      #expect(noFallback?.rationalePriorityList == nil)
    }
  }

  @Test func candidatesWithoutPriorityKeepBothPriorityFieldsNil() throws {
    try database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let session = HandoffSession(sourceType: "trip", sourceID: trip.id, taskType: "candidatePlaces", exportedPrompt: "")
      _ = try RecommendationSetImport.apply(
        candidates: [TripCandidate(name: "Unranked")], note: nil, into: trip.id, session: session, now: .now, in: db)
      let fetched = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db)
      let row = try #require(fetched)
      #expect(row.rationalePriority == nil)
      #expect(row.rationalePriorityOutOf == nil)
    }
  }

  @Test(arguments: [RecommendationHandoffTask.candidatePlaces, RecommendationHandoffTask.seedTrip])
  func tokenReusesOnlySessionsForTheSameTripAndTask(taskType: String) {
    let trip = UUID()
    let otherTrip = UUID()
    let token = UUID()
    let replacement = UUID()
    let original = HandoffSession(id: token, sourceType: "trip", sourceID: trip, taskType: taskType, exportedPrompt: "")
    let otherTask = taskType == RecommendationHandoffTask.seedTrip ? RecommendationHandoffTask.candidatePlaces : RecommendationHandoffTask.seedTrip
    let reused = RecommendationSetImport.session(token: token, existing: original, tripID: trip, taskType: taskType, now: .now, newID: replacement)
    let other = RecommendationSetImport.session(token: token, existing: original, tripID: otherTrip, taskType: taskType, now: .now, newID: replacement)
    let mismatched = RecommendationSetImport.session(token: token, existing: original, tripID: trip, taskType: otherTask, now: .now, newID: replacement)
    let absent = RecommendationSetImport.session(token: token, existing: nil, tripID: trip, taskType: taskType, now: .now, newID: replacement)
    #expect(reused == original)
    #expect(other.id == replacement)
    #expect(other.sourceID == otherTrip)
    #expect(mismatched.id == replacement)
    #expect(mismatched.taskType == otherTask)
    #expect(absent.id == token)
  }

}
