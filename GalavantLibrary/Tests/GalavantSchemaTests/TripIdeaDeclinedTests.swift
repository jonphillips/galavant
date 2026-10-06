import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies {
  try $0.bootstrapDatabase()
  $0.uuid = .incrementing
  $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
})
struct TripIdeaDeclinedTests {
  @Dependency(\.defaultDatabase) var database

  @Test func rawValueAndDeclinePreserveReasonAndRejectScheduledStop() async throws {
    #expect(TripIdeaStatus.declined.rawValue == 5)
    let (declined, scheduled) = try await database.write { db -> (TripIdea, TripIdea) in
      let trip = try Trip.create(name: "Denmark", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let firstID = UUID()
      let secondID = UUID()
      try Idea.insert {
        [
          Idea.Draft(Idea(id: firstID, name: "Zulu", travelPartyID: party.id)),
          Idea.Draft(Idea(id: secondID, name: "Alpha", travelPartyID: party.id)),
        ]
      }.execute(db)
      let first = try TripIdea.pull(ideaID: firstID, into: trip.id, status: .shortlisted, in: db)
      try TripIdea.find(first.id).update { $0.inlineNote = #bind("Existing rationale") }.execute(db)
      try TripIdea.decline(stopID: first.id, reason: "too far", in: db)
      let declined = try #require(try TripIdea.find(first.id).fetchOne(db))
      #expect(declined.status == .declined)
      #expect(declined.inlineNote == "Existing rationale\n\nRuled out: too far")
      let second = try TripIdea.pull(ideaID: secondID, into: trip.id, status: .scheduled, in: db)
      try TripIdea.decline(stopID: second.id, reason: "can't change", in: db)
      let stillScheduled = try #require(try TripIdea.find(second.id).fetchOne(db))
      #expect(stillScheduled.status == .scheduled)
      return (declined, stillScheduled)
    }
    #expect(declined.status == .declined)
    #expect(scheduled.status == .scheduled)
  }

  @Test func pullingAgainReusesTheDeclinedJoinAndKeepsItsNote() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let ideaID = UUID()
      try Idea.insert { Idea.Draft(Idea(id: ideaID, name: "Harbor", travelPartyID: party.id)) }
        .execute(db)
      let initial = try TripIdea.pull(ideaID: ideaID, into: trip.id, status: .considering, in: db)
      try TripIdea.decline(stopID: initial.id, reason: "closed", in: db)
      let pulled = try TripIdea.pull(ideaID: ideaID, into: trip.id, status: .shortlisted, in: db)
      #expect(pulled.id == initial.id)
      #expect(pulled.status == .shortlisted)
      #expect(pulled.inlineNote == "Ruled out: closed")
      #expect(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db).count == 1)
    }
  }

  @Test func ruledOutIsTitleOrderedAndExcludedFromTripPlanningBuckets() {
    let tripID = UUID()
    let alphaID = UUID()
    let zuluID = UUID()
    let alpha = TripIdea(id: UUID(), tripID: tripID, ideaID: alphaID, status: .declined)
    let zulu = TripIdea(id: UUID(), tripID: tripID, ideaID: zuluID, status: .declined)
    let plan = TripPlan(
      entries: [zulu, alpha],
      ideasByID: [alphaID: Idea(id: alphaID, name: "Alpha"), zuluID: Idea(id: zuluID, name: "Zulu")],
      lengthInDays: 2)
    #expect(plan.ruledOut.map(\.content.title) == ["Alpha", "Zulu"])
    #expect(plan.shortlist.isEmpty)
    #expect(plan.scheduled.isEmpty)
    #expect(plan.toBeScheduled.isEmpty)
    #expect(plan.itinerary.flatMap(\.stops).isEmpty)
    #expect(TripBookingRollup(plan: plan, currentDay: nil).items.isEmpty)
    #expect(!plan.isEmpty)
  }

  @Test func decliningAnAlternativeLeavesItsRingLikeRemoval() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let groupID = UUID()
      let members = (0..<3).map { index in
        TripIdea(
          id: UUID(), tripID: trip.id, ideaID: UUID(), status: .shortlisted,
          shortlistRank: index, alternativeGroupID: groupID, isActive: index == 0)
      }
      for member in members {
        try TripIdea.insert { TripIdea.Draft(member) }.execute(db)
      }
      try TripIdea.decline(stopID: members[0].id, reason: nil, in: db)
      let saved = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      #expect(saved.first { $0.id == members[0].id }?.status == .declined)
      #expect(saved.first { $0.id == members[0].id }?.alternativeGroupID == nil)
      let second = try #require(saved.first { $0.id == members[1].id })
      let third = try #require(saved.first { $0.id == members[2].id })
      #expect(second.alternativeGroupID == groupID)
      #expect(third.alternativeGroupID == groupID)
      #expect(second.isActive != third.isActive)
    }
  }
}
