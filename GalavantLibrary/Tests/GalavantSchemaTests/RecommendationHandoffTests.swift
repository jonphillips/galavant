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

  @Test func recommendationResolutionAutomaticallyFoldsDuplicateAndKeepsPlacement() async throws {
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
      try TripIdea.find(existing.id).update {
        $0.inlineNote = #bind("Keep this note")
        $0.rationaleWhy = #bind("The old evaluation")
        $0.rationalePriority = #bind(2)
        $0.rationalePriorityOutOf = #bind(5)
        $0.rationalePriorityList = #bind("Earlier list")
      }.execute(db)
      let duplicate = TripIdea(
        id: UUID(),
        tripID: trip.id,
        ideaID: nil,
        inlineTitle: "Lumiere Brasserie",
        inlineNote: "Try the tasting menu.",
        rationaleWhy: "The new evaluation",
        rationalePriority: 1,
        rationalePriorityOutOf: 4,
        rationalePriorityList: "Newer list",
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
      #expect(resolution.collision != nil)
      try resolution.collision?.action.apply(in: db)
      return (existing.id, duplicate.id, try #require(resolution.collision))
    }

    try await database.read { db in
      let fetched = try TripIdea.find(result.0).fetchOne(db)
      let remaining = try #require(fetched)
      #expect(try TripIdea.find(result.1).fetchOne(db) == nil)
      #expect(remaining.inlineNote == "Keep this note\n\nTry the tasting menu.")
      #expect(remaining.rationaleWhy == "The new evaluation")
      #expect(remaining.rationalePriority == 2)
      #expect(remaining.rationalePriorityOutOf == 5)
      #expect(remaining.rationalePriorityList == "Earlier list")
      #expect(remaining.status == .shortlisted)
    }
  }

  @Test func resolvingRuledOutUnresolvedStopKeepsItsStatusAndReason() async throws {
    let result = try await database.write { db -> (TripIdea, Idea?) in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      let stop = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: nil,
        inlineTitle: "Plose", inlineNote: "Save for a quieter season.", status: .declined
      )
      try TripIdea.insert { TripIdea.Draft(stop) }.execute(db)
      let resolution = try #require(try RecommendationResolution.confirm(
        candidateStopID: stop.id,
        capture: Place(
          id: UUID(), name: "Plose", latitude: 46.7, longitude: 11.7,
          mapItemIdentifier: "maps:plose"
        ).ideaCapture(),
        in: db
      ))
      let committed = try #require(try TripIdea.find(stop.id).fetchOne(db))
      let createdIdea = try Idea.find(resolution.capture.ideaID).fetchOne(db)
      return (committed, createdIdea)
    }

    #expect(result.0.status == .declined)
    #expect(result.0.inlineNote == "Save for a quieter season.")
    #expect(result.0.ideaID == result.1?.id)
    #expect(result.1?.name == "Plose")
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
      "GV-TRIP: \(handoff.sourceID)",
      "Call stage_trip_return with this trip if the chat has it; otherwise start the reply with the GV-HANDOFF: line.",
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
      Substring("GV-TRIP: \(handoff.sourceID)"),
      "Call stage_trip_return with this trip if the chat has it; otherwise start the reply with the GV-HANDOFF: line.",
      "Trip: Bavaria/Dolomites",
      "Trip notes: Keep the days relaxed.",
      "Stops so far:",
      "Day 1:",
      "- Alpine Museum (Bavaria)",
      "Ask: Recommend candidate places that fit this trip. Give options with a useful locality, search hint, and concise rationale."
    ])
  }

  @Test func tasteLinesFollowTripAndTripNotesInBrief() {
    let handoff = session()
    let lines = ["Our travel taste: relaxed luxury", "Jon's taste: food first"]
    let actual = RecommendationHandoffContract.brief(
      session: handoff,
      tripName: "Denmark",
      tripNotes: "Keep it relaxed.",
      plan: plan(),
      tasteLines: lines)

    #expect(actual.split(separator: "\n") == [
      Substring(handoff.header),
      Substring("GV-TRIP: \(handoff.sourceID)"),
      "Call stage_trip_return with this trip if the chat has it; otherwise start the reply with the GV-HANDOFF: line.",
      "Trip: Denmark",
      "Trip notes: Keep it relaxed.",
      "Our travel taste: relaxed luxury",
      "Jon's taste: food first",
      "Ask: Recommend candidate places that fit this trip. Give options with a useful locality, search hint, and concise rationale."
    ])
  }

  @Test func decodesCandidateFixtureWithoutLosingAdvisoryFields() throws {
    let fixture = try #require(
      Bundle.module.url(forResource: "recommendation-candidates", withExtension: "json")
    )
    let candidates = try TripCandidate.decodeReturn(String(contentsOf: fixture, encoding: .utf8)).candidates
    let candidate = try #require(candidates.only)

    #expect(candidate.name == "Lumiere Brasserie")
    #expect(candidate.locality == "Bolzano")
    #expect(candidate.searchHint == "Lumiere Brasserie Bolzano")
    #expect(candidate.rationale == "A relaxed dinner after the museum.\n\nIt keeps the evening walkable from the old town.")
    #expect(candidate.priority == 4)
    #expect(candidate.dayRef == "3")
    #expect(candidate.placementAfter == "Forestis")
  }

  @Test func v1CandidatePasteStillDecodesWithOlderMarkerWarning() throws {
    let body = "GV-CONTRACT: v1\n[{\"name\":\"Old format place\"}]"
    let routed = try RecommendationHandoffContract.marker.strippingMarker(from: body)
    #expect(routed.warning != nil)
    #expect(try TripCandidate.decodeReturn(routed.text).candidates.only?.name == "Old format place")
  }

  @Test func keepsTextAroundCandidateArraysAndObjectSummaryInOrder() throws {
    let bare = try TripCandidate.decodeReturn("[{\"name\":\"Plose\"}]")
    #expect(bare.candidates.only?.name == "Plose")
    #expect(bare.note == nil)

    let prose = try TripCandidate.decodeReturn("Before the list.\n[{\"name\":\"Plose\"}]\nAfter the list.")
    #expect(prose.note == "Before the list.\n\nAfter the list.")

    let fenced = try TripCandidate.decodeReturn("Here it is:\n```json\n[{\"name\":\"Plose\"}]\n```\nThat’s all.")
    #expect(fenced.note == "Here it is:\n\nThat’s all.")

    let wrapped = try TripCandidate.decodeReturn("{\"summary\":\"Look north for more places.\",\"candidates\":[{\"name\":\"Plose\"}],\"follow_up\":\"Save them for later.\"}")
    #expect(wrapped.candidates.only?.name == "Plose")
    #expect(wrapped.note == "summary: Look north for more places.\nfollow_up: Save them for later.")

    let curly = try TripCandidate.decodeReturn("{\"summary\":\"Try the “northern” loop.\",\"recommendations\":[{\"name\":\"Plose\"}]}")
    #expect(curly.note == "summary: Try the “northern” loop.")

    let nested = try TripCandidate.decodeReturn("{\"summary\":\"Try the north.\",\"details\":{\"area\":\"north\"},\"places\":[{\"name\":\"Plose\"}]}")
    #expect(nested.note == "summary: Try the north.")

    let placesWithProse = try TripCandidate.decodeReturn("Try the north.\n{\"places\":[{\"name\":\"Plose\"}]}")
    #expect(placesWithProse.candidates.only?.name == "Plose")
  }

  @Test(arguments: ["", "Start here {base}.\n", "GV-SEED\n"])
  func refusesSeedObjectsWithBasesInCandidatePaste(prefix: String) {
    let text = prefix + "{\"bases\":[{\"name\":\"Inn\"}],\"places\":[{\"name\":\"Museum\"}]}"
    #expect(throws: TripCandidateDecodeError.seedObject) { try TripCandidate.decodeReturn(text) }
  }

  @Test func seedBriefUsesTripContextAndV2ProjectInstructionsKeepTheCandidateClause() {
    let handoff = HandoffSession(
      sourceType: "trip", sourceID: UUID(), taskType: RecommendationHandoffTask.seedTrip,
      scopeKey: nil, exportedPrompt: ""
    )
    let brief = RecommendationHandoffContract.seedBrief(
      session: handoff, tripName: "Denmark", plan: plan(lengthInDays: 13)
    )
    #expect(brief == [
      handoff.header,
      "GV-TRIP: \(handoff.sourceID)",
      "Call stage_trip_return with this trip if the chat has it; otherwise start the reply with the GV-HANDOFF: line.",
      "Trip: Denmark",
      "Ask: Seed this Galavant trip from our conversation so far, using the seed format in the project instructions. That format replaces the candidate-places format for this reply."
    ].joined(separator: "\n"))
    #expect(brief.contains(handoff.header))
    #expect(brief.contains("Trip: Denmark"))
    #expect(brief.contains("using the seed format in the project instructions"))
    #expect(!brief.contains("Trip notes:"))
    #expect(RecommendationHandoffContract.marker.version == "v2")
    #expect(RecommendationHandoffContract.projectInstructions.contains("GV-CONTRACT: v2\n[{"))
    #expect(RecommendationHandoffContract.projectInstructions.contains("GV-CONTRACT: v2\", then a narrative"))
  }

  @Test func tasteLinesFollowTripInSeedBrief() {
    let handoff = HandoffSession(
      sourceType: "trip", sourceID: UUID(), taskType: RecommendationHandoffTask.seedTrip,
      scopeKey: nil, exportedPrompt: "")
    let brief = RecommendationHandoffContract.seedBrief(
      session: handoff, tripName: "Denmark", plan: plan(),
      tasteLines: ["Our travel taste: relaxed luxury"])

    #expect(brief.split(separator: "\n").contains("Our travel taste: relaxed luxury"))
    #expect(brief.range(of: "Trip: Denmark")!.lowerBound
      < brief.range(of: "Our travel taste: relaxed luxury")!.lowerBound)
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
      let candidate = try #require(TripCandidate.decodeReturn("[\(object)]").candidates.only)
      #expect(candidate.bookAhead == expected)
    }
  }

  @Test func projectInstructionsDocumentTheAdditiveBookAheadHint() {
    #expect(RecommendationHandoffContract.projectInstructions.contains("GV-CONTRACT: v2"))
    #expect(RecommendationHandoffContract.projectInstructions.contains("book_ahead"))
    #expect(RecommendationHandoffContract.projectInstructions.contains("timed entry, popular restaurant, show"))
  }

  @Test func projectInstructionsDefinePriorityAsOneBasedListRank() {
    #expect(RecommendationHandoffContract.projectInstructions.contains(
      "priority ranks this list: 1 is your first choice, 2 the next, and so on. Omit it if you can't rank."))
    #expect(RecommendationHandoffContract.projectInstructions.contains("\"priority\":1"))
    #expect(RecommendationHandoffContract.projectInstructions.contains("\"list\":\"Soho Indian\""))
    #expect(RecommendationHandoffContract.projectInstructions.contains("When you rank, also give list:"))
  }

  @Test func candidateListNamesAreTrimmedCappedAndOptional() throws {
    let trimmed = try #require(TripCandidate.decodeReturn(
      #"[{"name":"Cafe","priority":1,"list":"  Soho Indian  "}]"#).candidates.only)
    #expect(trimmed.list == "Soho Indian")
    let capped = try #require(TripCandidate.decodeReturn(
      #"[{"priority":1,"list":"12345678901234567890123456789012345678901"}]"#).candidates.only)
    #expect(capped.list?.count == 40)
    let empty = try #require(TripCandidate.decodeReturn(#"[{"priority":1,"list":"  "}]"#).candidates.only)
    #expect(empty.list == nil)
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

    #expect(candidates.candidates.only?.name == "Plose")
  }

  @Test func partialFieldsReachReviewWithoutBlockingIngestion() throws {
    let candidates = try TripCandidate.decodeReturn("[{\"search_hint\": \"Cable car near Brixen\"}]")
    let candidate = try #require(candidates.candidates.only)

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
    #expect(committed.inlineNote == nil)
    #expect(committed.rationaleWhy == "A relaxed dinner after the museum.")
    #expect(committed.rationaleFit == "Walkable from the old town.")
    #expect(committed.status == .considering)
    #expect(committed.shortlistRank == 4)
  }

  @Test func recommittingLegacyRationaleFillsEmptyFieldsAndClearsOnlyTheDuplicateNote() async throws {
    let candidate = TripCandidate(name: "Museum", why: "Worth the visit", fit: "Easy from the hotel", visit: "Tuesday")
    let updated = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Denmark", in: db)
      let original = try TripIdea.commit(candidate: candidate, into: trip.id, in: db)
      try TripIdea.find(original.id).update {
        $0.inlineNote = #bind(candidate.rationale)
        $0.rationaleVisit = #bind(nil as String?)
        $0.rationaleWhy = #bind(nil as String?)
        $0.rationaleFit = #bind(nil as String?)
      }.execute(db)

      return try TripIdea.commit(candidate: candidate, into: trip.id, in: db)
    }

    #expect(updated.rationaleVisit == "Tuesday")
    #expect(updated.rationaleWhy == "Worth the visit")
    #expect(updated.rationaleFit == "Easy from the hotel")
    #expect(updated.inlineNote == nil)
  }

  @Test func matchingCandidateSupersedesAnExistingPriorityPair() async throws {
    let rows = try await database.write { db -> (TripIdea, TripIdea) in
      let trip = try Trip.create(name: "Denmark", in: db)
      let candidate = TripCandidate(name: "Museum", priority: 2)
      let original = try TripIdea.commit(candidate: candidate, into: trip.id, priorityOutOf: 5, in: db)
      try TripIdea.find(original.id).update {
        $0.rationalePriority = #bind(nil as Int?)
        $0.rationalePriorityOutOf = #bind(nil as Int?)
      }.execute(db)
      let filled = try TripIdea.commit(candidate: candidate, into: trip.id, priorityOutOf: 7, in: db)
      let kept = try TripIdea.commit(
        candidate: TripCandidate(name: "Museum", priority: 1), into: trip.id, priorityOutOf: 9, in: db)
      return (filled, kept)
    }

    #expect(rows.0.rationalePriority == 2)
    #expect(rows.0.rationalePriorityOutOf == 7)
    #expect(rows.1.rationalePriority == 1)
    #expect(rows.1.rationalePriorityOutOf == 9)
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
    #expect(merge.updatedCandidates.map(\.id) == [original.id])
    #expect(try session.recommendationCandidates().map(\.id) == [original.id, newCandidate.id])
    expectNoDifference(
      session.candidateLinks.first(where: { $0.candidateID == original.id })?.tripIdeaID,
      linkedStopID
    )
  }

  @Test func rankedRereturnUpdatesRepeatsAndUnranksPlacesLeftOut() throws {
    let stored = [
      TripCandidate(id: UUID(-30), name: "One", why: "Old one", priority: 1, priorityOutOf: 5),
      TripCandidate(id: UUID(-31), name: "Two", priority: 2, priorityOutOf: 5),
      TripCandidate(id: UUID(-32), name: "Three", priority: 3, priorityOutOf: 5),
      TripCandidate(id: UUID(-33), name: "Four", priority: 4, priorityOutOf: 5),
      TripCandidate(id: UUID(-34), name: "Five", priority: 5, priorityOutOf: 5),
    ]
    let merge = RecommendationCandidateSet.merging(existing: stored, incoming: [
      TripCandidate(name: "ONE", why: "New one", priority: 3),
      TripCandidate(name: "Two", why: "New two", priority: 1),
      TripCandidate(name: "Three", why: "New three", priority: 2),
      TripCandidate(name: "Six", why: "New six", priority: 4),
    ])

    #expect(merge.addedCandidates.map(\.name) == ["Six"])
    #expect(merge.updatedCandidates.map(\.id) == stored.prefix(3).map(\.id))
    #expect(merge.unrankedCandidates.map(\.name) == ["Four", "Five"])
    #expect(merge.candidates.prefix(3).map(\.priority) == [3, 1, 2])
    #expect(merge.candidates.prefix(3).allSatisfy { $0.priorityOutOf == 4 })
    #expect(merge.candidates.prefix(3).map(\.why) == ["New one", "New two", "New three"])
    #expect(merge.candidates[3].priority == nil)
    #expect(merge.candidates[3].priorityOutOf == nil)
    #expect(merge.candidates.last?.priorityOutOf == 4)
  }

  @Test func repeatedPlacesWithinOneReturnDeduplicateBeforeStampingAndApplying() async throws {
    let values = try await database.write { db -> (RecommendationCandidateSet.Merge, TripIdea) in
      let trip = try Trip.create(name: "Denmark", in: db)
      let stop = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: nil, inlineTitle: "Cafe", status: .considering
      )
      try TripIdea.insert { TripIdea.Draft(stop) }.execute(db)
      let stored = TripCandidate(id: UUID(-50), name: "Cafe", priority: 1, priorityOutOf: 1)
      let merge = RecommendationCandidateSet.merging(existing: [stored], incoming: [
        TripCandidate(name: "Cafe", why: "First Cafe entry", priority: 1),
        TripCandidate(name: "cafe", why: "Duplicate Cafe entry", priority: 2),
        TripCandidate(name: "Bistro", why: "First Bistro entry", priority: 2),
        TripCandidate(name: "bistro", why: "Duplicate Bistro entry", priority: 1),
      ])

      let links = [HandoffCandidateLink(candidateID: stored.id, tripIdeaID: stop.id)]
      try RecommendationCandidateSet.applyReevaluation(merge, links: links, in: db)
      return (merge, try #require(try TripIdea.find(stop.id).fetchOne(db)))
    }

    #expect(values.0.updatedCandidates.map(\.id) == [UUID(-50)])
    #expect(values.0.addedCandidates.count == 1)
    #expect(values.0.addedCandidates.first?.name == "Bistro")
    #expect(values.0.candidates.count == 2)
    #expect(values.0.candidates.map(\.priorityOutOf) == [2, 2])
    #expect(values.0.candidates.map(\.why) == ["First Cafe entry", "First Bistro entry"])
    #expect(values.1.rationaleWhy == "First Cafe entry")
    #expect(values.1.rationalePriorityOutOf == 2)
  }

  @Test func unrankedRereturnUpdatesTextAndKeepsTheOldRankPair() {
    let stored = [TripCandidate(id: UUID(-35), name: "One", why: "Old", priority: 2, priorityOutOf: 5)]
    let merge = RecommendationCandidateSet.merging(
      existing: stored,
      incoming: [TripCandidate(name: "One", why: "New")]
    )

    #expect(merge.updatedCandidates.first?.why == "New")
    #expect(merge.candidates.first?.priority == 2)
    #expect(merge.candidates.first?.priorityOutOf == 5)
    #expect(merge.unrankedCandidates.isEmpty)
  }

  @Test func candidatePriorityOutOfUsesReturnStampAndLegacySessionCount() throws {
    let stamped = TripCandidate(id: UUID(-36), name: "One", priority: 1, priorityOutOf: 4)
    let unstamped = TripCandidate(id: UUID(-37), name: "Two", priority: 2)
    var session = HandoffSession(
      sourceType: "trip", sourceID: UUID(), taskType: RecommendationHandoffTask.candidatePlaces,
      exportedPrompt: "Prompt"
    )
    try session.storeRecommendationCandidates([stamped, unstamped])
    #expect(try session.recommendationCandidates().first?.priorityOutOf == 2)
    try session.replaceRecommendationCandidate(stamped)

    #expect(try session.priorityOutOf(for: stamped.id) == 4)
    #expect(try session.priorityOutOf(for: unstamped.id) == 2)
  }

  @Test func candidatePriorityOutOfRoundTripsAndOldPayloadsDecodeUnstamped() throws {
    let candidate = TripCandidate(name: "Cafe", priority: 1, priorityOutOf: 4)
    let encoded = try JSONEncoder().encode(candidate)
    let decoded = try JSONDecoder().decode(TripCandidate.self, from: encoded)
    #expect(decoded == candidate)
    let oldPayload = Data(#"{"name":"Cafe","priority":1}"#.utf8)
    #expect(try JSONDecoder().decode(TripCandidate.self, from: oldPayload).priorityOutOf == nil)
  }

  @Test func supersededRationaleReplacesTextAsAUnitAndLeavesTheStopNoteAlone() {
    let existing = TripRationale(
      visit: "Old visit", why: "Old why", fit: "Old fit", priority: 2, priorityOutOf: 5,
      note: "My note"
    )
    let newText = existing.superseded(by: TripRationale(
      visit: "New visit", why: nil, fit: "New fit", note: nil
    ))
    #expect(newText == TripRationale(
      visit: "New visit", why: nil, fit: "New fit", priority: 2, priorityOutOf: 5, note: "My note"
    ))
    let newRank = existing.superseded(by: TripRationale(
      visit: nil, why: nil, fit: nil, priority: 1, priorityOutOf: 4, note: nil
    ))
    #expect(newRank.priority == 1)
    #expect(newRank.priorityOutOf == 4)
    #expect(newRank.visit == "Old visit")
    #expect(newRank.note == "My note")
  }

  @Test func reevaluationChangesOnlyLiveRowsRationaleAndClearsOmittedRanks() async throws {
    let rows = try await database.write { db -> (TripIdea, TripIdea, TripIdea) in
      let trip = try Trip.create(name: "Denmark", in: db)
      let ringID = UUID()
      let updated = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: nil, inlineTitle: "Cafe",
        inlineNote: "My stop note", rationaleVisit: "Old visit", rationaleWhy: "Old why",
        rationaleFit: "Old fit", rationalePriority: 1, rationalePriorityOutOf: 2,
        status: .scheduled, shortlistRank: 7, dayRank: 3.5, alternativeGroupID: ringID,
        isActive: false, dayNumber: 3, dayPart: .lunch
      )
      let dropped = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: nil, inlineTitle: "Bistro",
        rationalePriority: 2, rationalePriorityOutOf: 2, status: .shortlisted, shortlistRank: 8
      )
      let declined = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: nil, inlineTitle: "Pub",
        rationalePriority: 3, rationalePriorityOutOf: 3, status: .declined
      )
      for row in [updated, dropped, declined] {
        try TripIdea.insert { TripIdea.Draft(row) }.execute(db)
      }

      let original = [
        TripCandidate(id: UUID(-41), name: "Cafe", why: "Old why", priority: 1, priorityOutOf: 3),
        TripCandidate(id: UUID(-42), name: "Bistro", priority: 2, priorityOutOf: 3),
        TripCandidate(id: UUID(-43), name: "Pub", priority: 3, priorityOutOf: 3),
      ]
      let incoming = [TripCandidate(name: "Cafe", why: "New why", priority: 1)]
      let merge = RecommendationCandidateSet.merging(existing: original, incoming: incoming)
      let links = [
        HandoffCandidateLink(candidateID: original[0].id, tripIdeaID: updated.id),
        HandoffCandidateLink(candidateID: original[1].id, tripIdeaID: dropped.id),
        HandoffCandidateLink(candidateID: original[2].id, tripIdeaID: declined.id),
      ]
      try RecommendationCandidateSet.applyReevaluation(merge, links: links, in: db)
      return (
        try #require(try TripIdea.find(updated.id).fetchOne(db)),
        try #require(try TripIdea.find(dropped.id).fetchOne(db)),
        try #require(try TripIdea.find(declined.id).fetchOne(db))
      )
    }

    #expect(rows.0.rationaleVisit == nil)
    #expect(rows.0.rationaleWhy == "New why")
    #expect(rows.0.rationaleFit == nil)
    #expect(rows.0.rationalePriority == 1)
    #expect(rows.0.rationalePriorityOutOf == 1)
    #expect(rows.0.inlineNote == "My stop note")
    #expect(rows.0.status == .scheduled)
    #expect(rows.0.dayNumber == 3)
    #expect(rows.0.dayPart == .lunch)
    #expect(rows.0.alternativeGroupID != nil)
    #expect(rows.0.isActive == false)
    #expect(rows.0.shortlistRank == 7)
    #expect(rows.1.rationalePriority == nil)
    #expect(rows.1.rationalePriorityOutOf == nil)
    #expect(rows.1.status == .shortlisted)
    #expect(rows.2.rationalePriority == 3)
    #expect(rows.2.rationalePriorityOutOf == 3)
  }

  @Test func chatRankMedalHasTheRightTiersAndAccessibleNames() {
    #expect(ChatRankMedal.tier(priority: 1, priorityOutOf: 5) == .gold)
    #expect(ChatRankMedal.tier(priority: 2, priorityOutOf: 5) == .silver)
    #expect(ChatRankMedal.tier(priority: 3, priorityOutOf: 5) == .bronze)
    #expect(ChatRankMedal.tier(priority: 4, priorityOutOf: 5) == nil)
    #expect(ChatRankMedal.tier(priority: 1, priorityOutOf: 1) == nil)
    #expect(ChatRankMedal.accessibilityLabel(priority: 1, priorityOutOf: nil) == "Chat's first choice")
    #expect(ChatRankMedal.accessibilityLabel(priority: 2, priorityOutOf: 5) == "Chat's second choice of 5")
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
    #expect(result.0.inlineNote == nil)
    #expect(result.0.rationaleWhy == "A relaxed dinner after the museum.")
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
