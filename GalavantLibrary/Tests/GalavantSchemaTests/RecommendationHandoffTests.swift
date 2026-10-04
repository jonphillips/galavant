import CustomDump
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

  @Test func recommendationResolutionDetectsCollisionAndActionAppliesBothChoices() async throws {
    let result = try await database.write { db -> (TripIdea.ID, TripIdea.ID, ResolveReconcile.Collision) in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let placeID = UUID()
      try Idea.insert {
        Idea.Draft(Idea(
          id: placeID,
          name: "Lumiere Brasserie",
          mapItemIdentifier: "maps:lumiere",
          travelPartyID: party.id
        ))
      }.execute(db)
      let existing = try TripIdea.pull(ideaID: placeID, into: trip.id, status: .shortlisted, in: db)
      try TripIdea.find(existing.id).update { $0.inlineNote = #bind("Keep this note") }.execute(db)
      let duplicate = TripIdea(
        id: UUID(),
        tripID: trip.id,
        ideaID: nil,
        inlineTitle: "Lumiere Brasserie",
        inlineNote: "Try the tasting menu.",
        status: .considering
      )
      try TripIdea.insert { TripIdea.Draft(duplicate) }.execute(db)
      let resolution = try #require(try RecommendationResolution.confirm(
        candidateStopID: duplicate.id,
        capture: Place(
          id: UUID(), name: "Lumiere Brasserie", latitude: 46.5, longitude: 11.3,
          mapItemIdentifier: "maps:lumiere"
        ).ideaCapture(),
        in: db
      ))
      return (existing.id, duplicate.id, try #require(resolution.collision))
    }

    try await database.write { db in
      try result.2.action(for: .keepBoth).apply(in: db)
      #expect(try TripIdea.where { $0.id.eq(result.0) || $0.id.eq(result.1) }.fetchAll(db).count == 2)
      try result.2.action(for: .merge).apply(in: db)
      let fetched = try TripIdea.find(result.0).fetchOne(db)
      let remaining = try #require(fetched)
      #expect(try TripIdea.find(result.1).fetchOne(db) == nil)
      #expect(remaining.inlineNote == "Keep this note\n\nTry the tasting menu.")
    }
  }

  private func session() -> HandoffSession {
    HandoffSession(
      sourceType: "trip",
      sourceID: UUID(),
      taskType: RecommendationHandoffTask.candidatePlaces,
      exportedPrompt: "")
  }

  private func plan(
    entries: [TripIdea] = [],
    ideas: [Idea] = [],
    stays: [TripStay] = [],
    lengthInDays: Int = 2
  ) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: lengthInDays,
      tripStays: stays)
  }

  @Test func briefListsRuledOutStopsAndTruncatesTheirNotes() throws {
    let tripID = UUID()
    let longNote = "Ruled out: " + String(repeating: "reason ", count: 30)
    let rows = [
      TripIdea(id: UUID(), tripID: tripID, ideaID: UUID(), inlineNote: longNote, status: .declined),
      TripIdea(id: UUID(), tripID: tripID, ideaID: UUID(), status: .declined),
    ]
    let ideas = [
      Idea(id: rows[0].ideaID!, name: "Alsik", regionName: "Sønderborg"),
      Idea(id: rows[1].ideaID!, name: "Bistro", regionName: "Aarhus"),
    ]
    let text = RecommendationHandoffContract.brief(
      session: session(), tripName: "Denmark", tripNotes: "", plan: plan(entries: rows, ideas: ideas))
    #expect(text.contains("Already ruled out (don't suggest again):"))
    #expect(text.contains("Alsik (Sønderborg) — Ruled out:"))
    #expect(text.contains("- Bistro (Aarhus)"))
    #expect(text.contains("…"))
    #expect(!text.contains("reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason reason"))
  }

  @Test func briefOmitsRuledOutSectionWhenEmpty() throws {
    let text = RecommendationHandoffContract.brief(
      session: session(), tripName: "Denmark", tripNotes: "", plan: plan())
    #expect(!text.contains("Already ruled out"))
  }

  private func ideaStop(
    tripID: Trip.ID,
    ideaID: Idea.ID,
    day: Int?,
    shortlistRank: Int = 0,
    dayRank: Double = 0
  ) -> TripIdea {
    TripIdea(
      id: UUID(),
      tripID: tripID,
      ideaID: ideaID,
      status: .scheduled,
      shortlistRank: shortlistRank,
      dayRank: dayRank,
      dayNumber: day)
  }

  @Test func scopeKeysRoundTripThroughTheirOpaqueEncoding() throws {
    let stayID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let transferID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let scopes: [RecommendationHandoffScope] = [.day(3), .stay(stayID), .transfer(transferID), .trip]

    for scope in scopes {
      #expect(try RecommendationHandoffScope(sourceType: scope.sourceType, scopeKey: scope.scopeKey) == scope)
    }
  }

  @Test func stopSummaryGroupsCurrentStopsByDayAndKeepsItineraryOrder() {
    let tripID = UUID()
    let museumID = UUID()
    let trailID = UUID()
    let cafeID = UUID()
    let hotelID = UUID()
    let dinnerID = UUID()
    let entries = [
      ideaStop(tripID: tripID, ideaID: trailID, day: 1, dayRank: 1),
      ideaStop(tripID: tripID, ideaID: museumID, day: 1, dayRank: 0),
      ideaStop(tripID: tripID, ideaID: cafeID, day: 2),
      ideaStop(tripID: tripID, ideaID: dinnerID, day: nil, shortlistRank: 4)
    ]
    let hotel = TripStay(id: UUID(), tripID: tripID, ideaID: hotelID, checkInDay: 1, checkOutDay: 2)
    let actual = RecommendationHandoffContract.stopSummary(plan: plan(
      entries: entries,
      ideas: [
        Idea(id: museumID, name: "Old Town Museum", regionName: "Bavaria"),
        Idea(id: trailID, name: "Mountain Trail", regionName: "Dolomites"),
        Idea(id: cafeID, name: "Lakeside Cafe", regionName: "Bavaria"),
        Idea(id: hotelID, name: "Alpine Lodge", regionName: "Cortina"),
        Idea(id: dinnerID, name: "Mountain Dinner", regionName: "Cortina")
      ],
      stays: [hotel]))

    #expect(actual == [
      "Day 1:",
      "- Old Town Museum (Bavaria)",
      "- Mountain Trail (Dolomites)",
      "Day 2:",
      "- Lakeside Cafe (Bavaria)",
      "To be scheduled:",
      "- Mountain Dinner (Cortina)",
      "Staying: Alpine Lodge (Cortina)"
    ])
  }

  @Test func stopSummaryOmitsLocalityForUnlocatedRegionAndFreeformStops() {
    let tripID = UUID()
    let unnamedRegionID = UUID()
    var freeform = TripIdea.freeform(id: UUID(), tripID: tripID, title: "Train to Cortina")
    freeform.apply(.day(1))

    let actual = RecommendationHandoffContract.stopSummary(plan: plan(
      entries: [
        ideaStop(tripID: tripID, ideaID: unnamedRegionID, day: 1),
        freeform
      ],
      ideas: [Idea(id: unnamedRegionID, name: "Mountain Pass")]))

    #expect(actual == [
      "Day 1:",
      "- Mountain Pass",
      "- Train to Cortina"
    ])
  }

  @Test func emptyPlanKeepsTheMinimalBriefWithoutAStopsHeader() {
    let handoff = session()
    let actual = RecommendationHandoffContract.brief(
      session: handoff,
      tripName: "Bavaria/Dolomites",
      tripNotes: "",
      plan: plan(lengthInDays: 1))

    #expect(actual == [
      handoff.header,
      "Trip: Bavaria/Dolomites",
      "Ask: Recommend candidate places that fit this trip. Give options with a useful locality, search hint, and concise rationale."
    ].joined(separator: "\n"))
  }

  @Test func tripNotesPrecedeTheStopsSectionAndAsk() {
    let tripID = UUID()
    let ideaID = UUID()
    let handoff = session()
    let actual = RecommendationHandoffContract.brief(
      session: handoff,
      tripName: "Bavaria/Dolomites",
      tripNotes: "Keep the days relaxed.",
      plan: plan(
        entries: [ideaStop(tripID: tripID, ideaID: ideaID, day: 1)],
        ideas: [Idea(id: ideaID, name: "Alpine Museum", regionName: "Bavaria")],
        lengthInDays: 1))

    #expect(actual.split(separator: "\n", omittingEmptySubsequences: false) == [
      Substring(handoff.header),
      "Trip: Bavaria/Dolomites",
      "Trip notes: Keep the days relaxed.",
      "Stops so far:",
      "Day 1:",
      "- Alpine Museum (Bavaria)",
      "Ask: Recommend candidate places that fit this trip. Give options with a useful locality, search hint, and concise rationale."
    ])
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

  @Test func bookAheadAcceptsBooleansAndKnownStringsWithoutRejectingDrift() throws {
    let cases: [(String, Bool?)] = [
      (#"{"book_ahead":true}"#, true),
      (#"{"book_ahead":false}"#, false),
      (#"{"book_ahead":"true"}"#, true),
      (#"{"book_ahead":"YeS"}"#, true),
      (#"{"book_ahead":"FALSE"}"#, false),
      (#"{"book_ahead":"no"}"#, false),
      (#"{"book_ahead":"maybe"}"#, nil),
      (#"{"book_ahead":1}"#, nil),
      (#"{"book_ahead":null}"#, nil),
      ("{}", nil),
    ]

    for (object, expected) in cases {
      let candidate = try #require(TripCandidate.decodeReturn("[\(object)]").only)
      #expect(candidate.bookAhead == expected)
    }
  }

  @Test func projectInstructionsDocumentTheAdditiveBookAheadHint() {
    #expect(RecommendationHandoffContract.projectInstructions.contains("GV-CONTRACT: v1"))
    #expect(RecommendationHandoffContract.projectInstructions.contains("book_ahead"))
    #expect(RecommendationHandoffContract.projectInstructions.contains("timed entry, popular restaurant, show"))
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

  @Test func bookAheadSeedsOnlyANewCandidateMarkedTrue() async throws {
    let committed = try await database.write { db -> [TripIdea] in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      return try [true, false, nil].map { hint in
        try TripIdea.commit(
          candidate: TripCandidate(name: "Place \(String(describing: hint))", bookAhead: hint),
          into: trip.id,
          in: db)
      }
    }

    #expect(committed.map(\.bookingStatus) == [.toBook, nil, nil])
  }

  @Test func bookAheadFillsAnUndecidedMatchedRowButNeverOverridesAChoice() async throws {
    let statuses = try await database.write { db -> [BookingStatus?] in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let undecided = try TripIdea.commit(
        candidate: TripCandidate(name: "Alpine Museum"), into: trip.id, in: db)
      let chosen = try TripIdea.commit(
        candidate: TripCandidate(name: "Mountain Theater"), into: trip.id, in: db)
      try TripIdea.setBookingStatus(.notNeeded, stopID: chosen.id, in: db)

      _ = try TripIdea.commit(
        candidate: TripCandidate(name: "Alpine Museum", bookAhead: true), into: trip.id, in: db)
      _ = try TripIdea.commit(
        candidate: TripCandidate(name: "Mountain Theater", bookAhead: true), into: trip.id, in: db)

      return try [undecided.id, chosen.id].map {
        try TripIdea.find($0).fetchOne(db)?.bookingStatus
      }
    }

    #expect(statuses == [.toBook, .notNeeded])
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

  @Test func repastingMergesByNormalizedNameAndLocalityWithoutLosingCommittedLinks() throws {
    let original = TripCandidate(
      id: UUID(-20), name: "Lumière Brasserie", locality: "Bolzano"
    )
    let newCandidate = TripCandidate(id: UUID(-21), name: "Plose", locality: "Brixen")
    let linkedStopID = UUID(-22)
    var session = HandoffSession(
      sourceType: "trip",
      sourceID: UUID(),
      taskType: RecommendationHandoffTask.candidatePlaces,
      exportedPrompt: "Prompt"
    )

    try session.storeRecommendationCandidates([original])
    session.link(candidateID: original.id, to: linkedStopID)
    let merge = try session.storeRecommendationCandidates([
      TripCandidate(name: "lumiere brasserie", locality: "BOLZANO"),
      newCandidate,
    ])

    expectNoDifference(merge.addedCandidates, [newCandidate])
    expectNoDifference(try session.recommendationCandidates(), [original, newCandidate])
    expectNoDifference(
      session.candidateLinks.first(where: { $0.candidateID == original.id })?.tripIdeaID,
      linkedStopID
    )
  }

  @Test func committingAcrossSessionsLinksTheExistingLiveRowInsteadOfInserting() async throws {
    let result = try await database.write { db -> (TripIdea.ID, HandoffCandidateLink?, Int) in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let resolvedIdea = Idea(
        id: UUID(), name: "Lumière Brasserie", travelPartyID: party.id
      )
      try Idea.insert { Idea.Draft(resolvedIdea) }.execute(db)
      let firstCandidate = TripCandidate(name: "Lumière Brasserie", locality: "Bolzano")
      var firstSession = HandoffSession(
        sourceType: "trip", sourceID: trip.id,
        taskType: RecommendationHandoffTask.candidatePlaces, exportedPrompt: "Prompt"
      )
      try firstSession.storeRecommendationCandidates([firstCandidate])
      let original = try TripIdea.commit(
        candidate: firstCandidate, into: trip.id, in: db
      )
      _ = try TripIdea.attachResolvedIdea(resolvedIdea.id, to: original.id, in: db)
      firstSession.link(candidateID: firstCandidate.id, to: original.id)
      let returningCandidate = TripCandidate(name: "lumiere brasserie", locality: "BOLZANO")
      var returningSession = HandoffSession(
        sourceType: "trip", sourceID: trip.id,
        taskType: RecommendationHandoffTask.candidatePlaces, exportedPrompt: "Prompt"
      )
      try returningSession.storeRecommendationCandidates([returningCandidate])
      let committed = try TripIdea.commit(
        candidate: returningCandidate, into: trip.id, in: db
      )
      returningSession.link(candidateID: returningCandidate.id, to: committed.id)
      let count = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
      return (original.id, returningSession.candidateLinks.only, count)
    }

    expectNoDifference(result.1?.tripIdeaID, result.0)
    expectNoDifference(result.2, 1)
  }

  @Test func terminalRowsDoNotSuppressANewCandidate() async throws {
    let result = try await database.write { db -> Int in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let original = try TripIdea.commit(
        candidate: TripCandidate(name: "Lumière Brasserie"), into: trip.id, in: db
      )
      try TripIdea.setStatus(.skipped, stopID: original.id, in: db)
      _ = try TripIdea.commit(
        candidate: TripCandidate(name: "lumiere brasserie"), into: trip.id, in: db
      )
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }

    expectNoDifference(result, 2)
  }

  @Test func candidateLocalityDistinguishesSameNamedResolvedPlaces() async throws {
    let counts = try await database.write { db -> (Int, Int) in
      let trip = try Trip.create(name: "European capitals", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let vienna = Idea(
        id: UUID(),
        name: "Café Central",
        address: "Herrengasse 14, Vienna, Austria",
        travelPartyID: party.id
      )
      try Idea.insert { Idea.Draft(vienna) }.execute(db)
      let original = try TripIdea.commit(
        candidate: TripCandidate(name: "Café Central", locality: "Vienna"), into: trip.id, in: db
      )
      _ = try TripIdea.attachResolvedIdea(vienna.id, to: original.id, in: db)

      _ = try TripIdea.commit(
        candidate: TripCandidate(name: "Cafe Central", locality: "Vienna"), into: trip.id, in: db
      )
      let afterMatchingLocality = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)

      _ = try TripIdea.commit(
        candidate: TripCandidate(name: "Cafe Central", locality: "Madrid"), into: trip.id, in: db
      )
      let afterDifferentLocality = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
      return (afterDifferentLocality, afterMatchingLocality)
    }

    expectNoDifference(counts.0, 2)
    expectNoDifference(counts.1, 1)
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
        capture: Place(
          id: UUID(),
          name: "Lumiere Brasserie",
          latitude: 46.4983,
          longitude: 11.3548,
          regionName: "Bolzano",
          kind: .food,
          url: "https://lumiere.example",
          address: "Piazza Walther 1, Bolzano",
          mapItemIdentifier: "maps:lumiere-bolzano"
        ).ideaCapture(),
        in: db
      )
      // Reused an existing pool idea via dedup, so it is not freshly minted.
      #expect(resolution?.capture.ideaID == existingID)
      #expect(resolution?.capture.isNew == false)
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
        capture: Place(
          id: UUID(),
          name: "Leutasch Gorge",
          latitude: 47.37,
          longitude: 11.23,
          kind: .sight,
          mapItemIdentifier: "maps:leutasch-gorge"
        ).ideaCapture(),
        in: db
      ))
      // A fresh place with no pool match — this resolution minted the idea.
      #expect(resolution.capture.isNew)

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
        capture: Place(
          id: UUID(),
          name: "Leutasch Gorge",
          latitude: 47.37,
          longitude: 11.23,
          kind: .sight,
          mapItemIdentifier: "maps:leutasch-gorge"
        ).ideaCapture(),
        in: db
      ))
      // A photo attached to the resolved idea makes it referenced beyond this stop.
      try ImageAsset.store(
        ideaID: resolution.capture.ideaID,
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
        capture: Place(
          id: UUID(), name: "Neustift Abbey", latitude: 46.755, longitude: 11.651,
          mapItemIdentifier: "maps:neustift-abbey"
        ).ideaCapture(),
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
