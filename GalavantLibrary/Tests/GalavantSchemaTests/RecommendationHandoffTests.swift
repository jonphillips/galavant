import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct RecommendationHandoffTests {
  @Dependency(\.defaultDatabase) var database

  @Test func scopeKeysRoundTripThroughTheirOpaqueEncoding() throws {
    let stayID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let transferID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let scopes: [RecommendationHandoffScope] = [.day(3), .stay(stayID), .transfer(transferID), .trip]

    for scope in scopes {
      #expect(try RecommendationHandoffScope(sourceType: scope.sourceType, scopeKey: scope.scopeKey) == scope)
    }
  }

  @Test func decodesCandidateFixtureWithoutLosingAdvisoryFields() throws {
    let fixture = try #require(
      Bundle.module.url(forResource: "recommendation-candidates", withExtension: "json")
    )
    let candidates = try TripCandidate.decodeReturn(String(contentsOf: fixture, encoding: .utf8))
    let candidate = try #require(candidates.only)

    #expect(candidate.name == "Lumiere Brasserie")
    #expect(candidate.locality == "Bolzano")
    #expect(candidate.searchHint == "Lumiere Brasserie Bolzano")
    #expect(candidate.rationale == "A relaxed dinner after the museum.\n\nIt keeps the evening walkable from the old town.")
    #expect(candidate.priority == 4)
    #expect(candidate.dayRef == "3")
    #expect(candidate.placementAfter == "Forestis")
  }

  @Test func malformedReturnFailsLoudly() {
    #expect(throws: TripCandidateDecodeError.malformedJSON) {
      try TripCandidate.decodeReturn("[{\"name\": }]")
    }
  }

  @Test func emptyReturnFailsLoudlyAtTheDecodeBoundary() {
    #expect(throws: TripCandidateDecodeError.emptyCandidates) {
      try TripCandidate.decodeReturn("[]")
    }
  }

  @Test func ignoresAStrayOpeningBracketBeforeTheCandidateArray() throws {
    let candidates = try TripCandidate.decodeReturn(
      "The output has a stray [ in this sentence.\n[{\"name\": \"Plose\"}]"
    )

    #expect(candidates.only?.name == "Plose")
  }

  @Test func partialFieldsReachReviewWithoutBlockingIngestion() throws {
    let candidates = try TripCandidate.decodeReturn("[{\"search_hint\": \"Cable car near Brixen\"}]")
    let candidate = try #require(candidates.only)

    #expect(candidate.name == nil)
    #expect(candidate.searchHint == "Cable car near Brixen")
    #expect(candidate.suggestedTitle == "Cable car near Brixen")
  }

  @Test func candidateCommitsAsAConsideringFreeformTripIdea() async throws {
    let committed = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      return try TripIdea.commit(
        candidate: TripCandidate(
          name: "Lumiere Brasserie",
          locality: "Bolzano",
          why: "A relaxed dinner after the museum.",
          fit: "Walkable from the old town.",
          priority: 4
        ),
        into: trip.id,
        in: db
      )
    }

    #expect(committed.ideaID == nil)
    #expect(committed.inlineTitle == "Lumiere Brasserie")
    #expect(committed.inlineNote == "A relaxed dinner after the museum.\n\nWalkable from the old town.")
    #expect(committed.status == .considering)
    #expect(committed.shortlistRank == 4)
  }

  @Test func sessionRetainsTheCandidateSetAndItsCommittedStopLinksLocally() throws {
    let candidate = TripCandidate(name: "Lumiere Brasserie", locality: "Bolzano")
    let otherCandidate = TripCandidate(name: "Plose", locality: "Brixen")
    let linkedStopID = UUID()
    var session = HandoffSession(
      sourceType: "trip",
      sourceID: UUID(),
      taskType: RecommendationHandoffTask.candidatePlaces,
      exportedPrompt: "Prompt"
    )

    try session.storeRecommendationCandidates([candidate, otherCandidate])
    session.link(candidateID: candidate.id, to: linkedStopID)
    try session.replaceRecommendationCandidate(TripCandidate(id: otherCandidate.id, name: "Plose Cable Car"))

    #expect(try session.recommendationCandidates().map(\.name) == ["Lumiere Brasserie", "Plose Cable Car"])
    #expect(session.candidateLinks.count == 2)
    #expect(session.candidateLinks.first(where: { $0.candidateID == candidate.id })?.tripIdeaID == linkedStopID)
    #expect(session.hasCommittedRecommendationCandidates)
  }

  @Test func sessionIsNotEvaluatableUntilAReviewedCandidateIsCommitted() throws {
    let candidate = TripCandidate(name: "Lumiere Brasserie")
    var session = HandoffSession(
      sourceType: "trip",
      sourceID: UUID(),
      taskType: RecommendationHandoffTask.candidatePlaces,
      exportedPrompt: "Prompt"
    )

    try session.storeRecommendationCandidates([candidate])
    #expect(!session.hasCommittedRecommendationCandidates)

    session.link(candidateID: candidate.id, to: UUID())
    #expect(session.hasCommittedRecommendationCandidates)
  }

  @Test func savingAnUnresolvedCandidateMovesItToTheShortlistWithoutMintingAnIdea() async throws {
    let saved = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let candidate = try TripIdea.commit(
        candidate: TripCandidate(name: "Lumiere Brasserie", why: "A relaxed dinner after the museum."),
        into: trip.id,
        in: db
      )
      try TripIdea.setStatus(.shortlisted, stopID: candidate.id, in: db)
      return try #require(try TripIdea.find(candidate.id).fetchOne(db))
    }

    #expect(saved.status == .shortlisted)
    #expect(saved.ideaID == nil)
  }

  @Test func confirmingACandidateReusesCaptureDedupAndPreservesItsRationale() async throws {
    let result = try await database.write { db -> (TripIdea, [Idea]) in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let candidate = try TripIdea.commit(
        candidate: TripCandidate(name: "Lumiere Brasserie", why: "A relaxed dinner after the museum."),
        into: trip.id,
        in: db
      )
      let party = try TravelParty.ensureDefault(in: db)
      let existingID = UUID()
      try Idea.insert {
        Idea.Draft(Idea(
          id: existingID,
          name: "Lumiere Brasserie",
          mapItemIdentifier: "maps:lumiere-bolzano",
          travelPartyID: party.id
        ))
      }
      .execute(db)

      let resolution = try RecommendationResolution.confirm(
        candidateStopID: candidate.id,
        place: Place(
          id: UUID(),
          name: "Lumiere Brasserie",
          latitude: 46.4983,
          longitude: 11.3548,
          regionName: "Bolzano",
          kind: .food,
          url: "https://lumiere.example",
          address: "Piazza Walther 1, Bolzano",
          mapItemIdentifier: "maps:lumiere-bolzano"
        ),
        in: db
      )
      // Reused an existing pool idea via dedup, so it is not freshly minted.
      #expect(resolution?.ideaID == existingID)
      #expect(resolution?.isNew == false)
      return (
        try #require(try TripIdea.find(candidate.id).fetchOne(db)),
        try Idea.all.fetchAll(db)
      )
    }

    #expect(result.0.ideaID == result.1.only?.id)
    #expect(result.0.inlineNote == "A relaxed dinner after the museum.")
    #expect(result.1.count == 1)
    #expect(result.1.only?.name == "Lumiere Brasserie")
    #expect(result.1.only?.regionName == "Bolzano")
    #expect(result.1.only?.kind == .food)
    #expect(result.1.only?.latitude == 46.4983)
    #expect(result.1.only?.address == "Piazza Walther 1, Bolzano")
    #expect(result.1.only?.url == "https://lumiere.example")
  }

  @Test func detachingAMintedCandidateUnlinksItAndDeletesTheOrphanIdea() async throws {
    let result = try await database.write { db -> (TripIdea, [Idea]) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let candidate = try TripIdea.commit(
        candidate: TripCandidate(name: "Leutasch Gorge"),
        into: trip.id,
        in: db
      )
      let resolution = try #require(try RecommendationResolution.confirm(
        candidateStopID: candidate.id,
        place: Place(
          id: UUID(),
          name: "Leutasch Gorge",
          latitude: 47.37,
          longitude: 11.23,
          kind: .sight,
          mapItemIdentifier: "maps:leutasch-gorge"
        ),
        in: db
      ))
      // A fresh place with no pool match — this resolution minted the idea.
      #expect(resolution.isNew)

      let detached = try TripIdea.detachResolvedIdea(
        from: candidate.id,
        deletingOrphanedIdea: true,
        in: db
      )
      return (try #require(detached), try Idea.all.fetchAll(db))
    }

    // Candidate is unresolved again and the throwaway idea it minted is gone.
    #expect(result.0.ideaID == nil)
    #expect(result.1.isEmpty)
  }

  @Test func detachingKeepsAMintedIdeaThatSomethingElseStillReferences() async throws {
    let result = try await database.write { db -> (TripIdea, [Idea]) in
      let trip = try Trip.create(name: "Bavaria", in: db)
      let candidate = try TripIdea.commit(
        candidate: TripCandidate(name: "Leutasch Gorge"),
        into: trip.id,
        in: db
      )
      let resolution = try #require(try RecommendationResolution.confirm(
        candidateStopID: candidate.id,
        place: Place(
          id: UUID(),
          name: "Leutasch Gorge",
          latitude: 47.37,
          longitude: 11.23,
          kind: .sight,
          mapItemIdentifier: "maps:leutasch-gorge"
        ),
        in: db
      ))
      // A photo attached to the resolved idea makes it referenced beyond this stop.
      try ImageAsset.store(
        ideaID: resolution.ideaID,
        display: Data([0x1]),
        thumbnail: Data([0x2]),
        id: UUID(),
        in: db
      )

      let detached = try TripIdea.detachResolvedIdea(
        from: candidate.id,
        deletingOrphanedIdea: true,
        in: db
      )
      return (try #require(detached), try Idea.all.fetchAll(db))
    }

    // Unlinked from the candidate, but the idea survives because the photo needs it.
    #expect(result.0.ideaID == nil)
    #expect(result.1.count == 1)
    #expect(result.1.only?.name == "Leutasch Gorge")
  }

  @Test func aConfirmedWebsiteWriteBackUpdatesOnlyTheResolvedIdea() async throws {
    let website = URL(string: "https://www.abbazianovacella.it")!
    let saved = try await database.write { db -> Idea in
      let party = try TravelParty.ensureDefault(in: db)
      let idea = Idea(id: UUID(), name: "Neustift Abbey", travelPartyID: party.id)
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      try Idea.setWebsite(website, for: idea.id, in: db)
      return try #require(try Idea.find(idea.id).fetchOne(db))
    }

    #expect(saved.url == website.absoluteString)
  }

  @Test func resolvingAnItineraryFreeformCandidateUpgradesItsExistingStop() async throws {
    let upgraded = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let candidate = try TripIdea.commit(
        candidate: TripCandidate(name: "Neustift Abbey", why: "A quiet afternoon."),
        into: trip.id,
        in: db
      )
      try TripIdea.scheduleUnplaced(stopID: candidate.id, in: db)
      _ = try RecommendationResolution.confirm(
        candidateStopID: candidate.id,
        place: Place(
          id: UUID(), name: "Neustift Abbey", latitude: 46.755, longitude: 11.651,
          mapItemIdentifier: "maps:neustift-abbey"
        ),
        in: db
      )
      return try #require(try TripIdea.find(candidate.id).fetchOne(db))
    }

    #expect(upgraded.status == .scheduled)
    #expect(upgraded.ideaID != nil)
  }

  @Test func chooseOneBuildsAnAlternativesRingForCandidates() async throws {
    let result = try await database.write { db -> (UUID, [TripIdea]) in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let first = try TripIdea.commit(
        candidate: TripCandidate(name: "Plose", why: "Mountain day."),
        into: trip.id,
        in: db
      )
      let second = try TripIdea.commit(
        candidate: TripCandidate(name: "Seceda", why: "Another mountain day."),
        into: trip.id,
        in: db
      )
      let groupID = try #require(
        try TripIdea.chooseOne(among: [first.id, second.id], activeStopID: second.id, in: db)
      )
      return (groupID, try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db))
    }

    #expect(result.1.map(\.alternativeGroupID).allSatisfy { $0 == result.0 })
    #expect(result.1.first(where: { $0.isActive })?.inlineTitle == "Seceda")
    #expect(result.1.allSatisfy { $0.status == .considering })
  }

  @Test func restoringADismissedCandidateReconstitutesItsAlternativesRing() async throws {
    let restored = try await database.write { db -> (UUID, TripIdea.ID, [TripIdea]) in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let first = try TripIdea.commit(candidate: TripCandidate(name: "Plose"), into: trip.id, in: db)
      let second = try TripIdea.commit(candidate: TripCandidate(name: "Seceda"), into: trip.id, in: db)
      let groupID = try #require(
        try TripIdea.chooseOne(among: [first.id, second.id], activeStopID: first.id, in: db)
      )
      let originalFirst = try #require(try TripIdea.find(first.id).fetchOne(db))
      try TripIdea.remove(stopID: first.id, in: db)
      try TripIdea.insert { TripIdea.Draft(originalFirst) }.execute(db)
      #expect(
        try TripIdea.restoreAlternativeRing(
          memberIDs: [first.id, second.id],
          activeStopID: first.id,
          groupID: groupID,
          in: db
        )
      )
      return (groupID, first.id, try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db))
    }

    #expect(restored.2.map(\.alternativeGroupID).allSatisfy { $0 == restored.0 })
    #expect(restored.2.first(where: \.isActive)?.id == restored.1)
  }
}

private extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
