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
      #expect(rows[0].inlineNote == "A good fit")
      #expect(rows[0].ideaID == nil)
      #expect(try Idea.fetchCount(db) == ideasBefore)
      #expect(documents.count == 1)
      #expect(first.session.candidateLinks.first?.tripIdeaID == retry.session.candidateLinks.first?.tripIdeaID)
      #expect(retry.remainingCount == 1)
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
