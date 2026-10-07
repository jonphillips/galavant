import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies {
  try $0.bootstrapDatabase()
  $0.uuid = .incrementing
  $0.date = .constant(Date(timeIntervalSince1970: 1_798_790_400))
})
struct SeedPlanTests {
  @Dependency(\.defaultDatabase) var database
  @Dependency(\.date) var date

  @Test func fixturePlansAndCommitsTheWholeSeedAndReseedDefaultsOff() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "seed-denmark", withExtension: "txt"))
    let seed = try SeedReturn.decode(String(contentsOf: fixture, encoding: .utf8))
    let (tripID, statuses, stays, rings, documentBody, importedSession) = try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let party = try TravelParty.ensureDefault(in: db)
      let regions = ["South Funen", "Møn", "Copenhagen"].enumerated().map { index, name in
        MapRegion(
          id: UUID(), name: name, centerLatitude: Double(index), centerLongitude: Double(index),
          latitudeDelta: 1, longitudeDelta: 1, travelPartyID: party.id
        )
      }
      try MapRegion.insert { regions.map(MapRegion.Draft.init) }.execute(db)
      let context = SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: regions
      )
      let plan = SeedPlan.make(from: seed, trip: trip, context: context)
      #expect(plan.tripEdit.includeLength)
      #expect(plan.tripEdit.includeCertainty)
      #expect(plan.ignoredGroups == ["Dragsholm meal", "South Funen walk"])
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      let imported = try SeedPlan.commit(plan, tripID: trip.id, session: session, now: date.now, in: db)
      let savedTrip = try #require(try Trip.find(trip.id).fetchOne(db))
      let rows = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let stays = try TripStay.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let documents = try TripDocument.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let dayRegions = try TripDayRegion.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let rings = Set(rows.compactMap(\.alternativeGroupID))
      #expect(savedTrip.lengthInDays == 13)
      #expect(savedTrip.targetYear == 2027)
      #expect(stays.count == 3)
      #expect(stays.map(\.bookingStatus) == [.toBook, .toBook, .toBook])
      #expect(rows.filter { $0.status == .shortlisted }.count == 4)
      #expect(rows.filter { $0.status == .considering }.count == 12)
      #expect(rows.filter { $0.status == .declined }.count == 21)
      #expect(rows.filter { $0.status == .declined }.allSatisfy { $0.bookingStatus == nil })
      #expect(rows.filter {
        $0.status == .declined && ($0.inlineNote?.contains("Deferred —") ?? false)
      }.count == 16)
      #expect(rings.count == 2)
      let ringNames = Set(rings.map { groupID in
        Set(rows.filter { $0.alternativeGroupID == groupID }.compactMap(\.inlineTitle))
      })
      #expect(ringNames == [
        Set(["Norðdisk", "Vester Skerninge Kro"]),
        Set(["Restaurant Egn", "Bryghuset Møn"]),
      ])
      #expect(documents.count == 1)
      #expect(documents.first?.origin == .seed)
      #expect(documents.first?.body == seed.narrative)
      let bookingNames = Set(rows.filter { $0.bookingStatus == .toBook }.compactMap(\.inlineTitle))
      #expect(bookingNames == Set([
        "Spodsbjerg–Tårs ferry", "Restaurant ND122", "Norðdisk", "Vester Skerninge Kro",
        "Restaurant Egn", "Bryghuset Møn", "Dragsholm Slot Bistro", "Søllerød Kro",
      ]))
      #expect(dayRegions.count == 12)
      #expect(dayRegions.filter { $0.regionID == regions[0].id }.map(\.dayNumber) == [1, 2, 3])
      #expect(dayRegions.filter { $0.regionID == regions[1].id }.map(\.dayNumber) == [4, 5, 6])
      #expect(dayRegions.filter { $0.regionID == regions[2].id }.map(\.dayNumber) == [7, 8, 9, 10, 11, 12])
      return (trip.id, rows.map(\.status), stays.count, rings.count, documents.first?.body, imported)
    }

    #expect(statuses.count == 37)
    #expect(stays == 3)
    #expect(rings == 2)
    #expect(documentBody == seed.narrative)
    #expect(importedSession.session.hasCommittedRecommendationCandidates)

    try await database.write { db in
      let trip = try #require(try Trip.find(tripID).fetchOne(db))
      let rows = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
      let stays = try TripStay.where { $0.tripID.eq(tripID) }.fetchAll(db)
      let secondPlan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: rows, ideasByID: [:], stays: stays,
        tripRegions: [], partyRegions: []
      ))
      #expect(secondPlan.places.allSatisfy { !$0.include })
      #expect(secondPlan.stays.allSatisfy { !$0.include })
    }
  }

  @Test func oversizedDocumentFailsBeforeWritingAnySeedRows() async throws {
    let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Only row\"}]}")
    try await database.write { db in
      let trip = try Trip.create(name: "Rollback", in: db)
      var oversized = seed
      oversized.narrative = String(repeating: "x", count: 512_001)
      let plan = SeedPlan.make(from: oversized, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
      ))
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      #expect(throws: TripDocumentError.tooLarge) {
        try SeedPlan.commit(plan, tripID: trip.id, session: session, now: date.now, in: db)
      }
      #expect(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db) == 0)
      #expect(try TripDocument.where { $0.tripID.eq(trip.id) }.fetchCount(db) == 0)
    }
  }

  @Test func verdictEditsOnExistingRowsAreComparedWithTheOriginalStatusAtCommit() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Existing stop", in: db)
      let existing = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: nil, inlineTitle: "Already here", status: .considering
      )
      try TripIdea.insert { TripIdea.Draft(existing) }.execute(db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Already here\",\"verdict\":\"considering\"}]}")
      var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [existing], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
      ))
      plan.places[0].include = true
      plan.places[0].place.verdict = .declined
      #expect(plan.places[0].statusUpdate)
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      try SeedPlan.commit(plan, tripID: trip.id, session: session, now: date.now, in: db)
      #expect(try TripIdea.find(existing.id).fetchOne(db)?.status == .declined)
    }
  }

  @Test func ringEligibilityRecomputesAfterAnOptionIsTurnedOff() throws {
    let trip = Trip(
      id: UUID(), name: "Alternatives", certaintyStage: .someday, lengthInDays: Trip.defaultLengthInDays
    )
    let seed = try SeedReturn.decode("""
      GV-SEED
      {"places":[{"name":"One","verdict":"core","group":"dinner"},{"name":"Two","verdict":"core","group":"dinner"}]}
      """)
    var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
      trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
    ))
    #expect(plan.formsRing(at: 0))
    #expect(plan.effectiveStatus(ofPlaceAt: 0) == .considering)
    plan.places[1].include = false
    #expect(!plan.formsRing(at: 0))
    #expect(plan.effectiveStatus(ofPlaceAt: 0) == .shortlisted)
  }

  @Test func includedStayExtendsASevenDayTripEvenWithoutASeedLength() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Long stay", in: db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"bases\":[{\"name\":\"Long base\",\"check_in_day\":11,\"check_out_day\":13}],\"places\":[{}]}")
      let plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
      ))
      #expect(seed.trip.lengthDays == nil)
      #expect(plan.forcedLengthDays == 13)
      #expect(plan.shouldIncludeLength)
      #expect(plan.effectiveLengthDays == 13)
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      try SeedPlan.commit(plan, tripID: trip.id, session: session, now: date.now, in: db)
      #expect(try Trip.find(trip.id).fetchOne(db)?.lengthInDays == 13)
    }
  }

  @Test func quarterWithoutAnyKnownYearDoesNotEnableCertaintyImport() throws {
    let trip = Trip(id: UUID(), name: "Quarter only")
    let seed = try SeedReturn.decode("GV-SEED\n{\"trip\":{\"quarter\":2},\"places\":[{}]}")
    let plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
      trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
    ))
    #expect(!plan.tripEdit.includeCertainty)
    #expect(plan.tripEdit.year == nil)
  }

  @Test func confirmedPoolMatchLinksAndMovesPlaceNotesIntoEvaluation() async throws {
    try await database.write { db in
      let party = try TravelParty.ensureDefault(in: db)
      let trip = try Trip.create(name: "Denmark", in: db)
      let idea = Idea(
        id: UUID(), name: "Dyvig Badehotel", address: "Nordborg, Denmark", travelPartyID: party.id
      )
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      let seed = try SeedReturn.decode("""
        GV-SEED
        {"places":[{"name":"DYVIG BADEHOTEL ApS","locality":"Nordborg","verdict":"deferred","future_trip":"Northern Denmark","reason":"Save for later","place_notes":"Rooms vary; ask for the larger room."}]}
        """)
      var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [idea.id: idea], stays: [],
        tripRegions: [], partyRegions: [], poolIdeas: [idea]
      ))
      #expect(plan.places[0].poolMatch == .idea(idea))
      plan.places[0].matchConfirmed = true
      plan.places[0].confirmedIdeaID = idea.id
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      try SeedPlan.commit(
        plan, tripID: trip.id, session: session, now: date.now, in: db
      )
      let row = try #require(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db))
      #expect(row.ideaID == idea.id)
      #expect(row.status == .declined)
      #expect(!(row.inlineNote?.contains("About the place:") ?? false))
      #expect(row.inlineNote?.contains("Deferred — Northern Denmark") == true)
      let evaluation = try #require(try IdeaEvaluation.where { $0.ideaID.eq(idea.id) }.fetchOne(db))
      #expect(evaluation.sourceName == "Trip research")
      #expect(evaluation.kind == .text)
      #expect(evaluation.nativeValueText == "Rooms vary; ask for the larger room.")
      #expect(evaluation.nativeDisplay == "Research note")
      #expect(evaluation.evaluationDate == date.now)
      #expect(evaluation.confidence == .inferred)
      #expect(evaluation.staleness == .current)
      #expect(evaluation.summary == evaluation.nativeValueText)
    }
  }

  @Test func mapConfirmationRunsThroughCaptureMergeInsideImport() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Dyvig Badehotel\",\"verdict\":\"considering\",\"place_notes\":\"Ask about room size.\"}]}")
      var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
      ))
      plan.places[0].matchConfirmed = true
      let mapPlace = Place(
        id: UUID(), name: "Dyvig Badehotel", latitude: 55.0, longitude: 9.0,
        address: "Nordborg, Denmark", mapItemIdentifier: "maps.dyvig"
      )
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      let result = try SeedPlan.commit(
        plan, tripID: trip.id, session: session, now: date.now,
        mapCaptures: [plan.places[0].id: mapPlace.ideaCapture()], in: db
      )
      let row = try #require(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db))
      #expect(row.ideaID != nil)
      #expect(!(row.inlineNote?.contains("About the place:") ?? false))
      let ideaID = try #require(row.ideaID)
      #expect(try IdeaEvaluation.where { $0.ideaID.eq(ideaID) }.fetchCount(db) == 1)
      #expect(result.mapRowOutcomes == [SeedMapRowOutcome(
        rowID: plan.places[0].id, rowTitle: "Dyvig Badehotel", resolution: .resolved(ideaID)
      )])
    }
  }

  @Test func collisionDetachesConfirmedMapIdeaAndReturnsTheSeedRowForResolution() async throws {
    try await database.write { db in
      let party = try TravelParty.ensureDefault(in: db)
      let trip = try Trip.create(name: "Denmark", in: db)
      let existingIdea = Idea(
        id: UUID(), name: "Restaurant ND122", mapItemIdentifier: "maps.nd122", travelPartyID: party.id
      )
      let existingStop = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: existingIdea.id, inlineTitle: nil, status: .shortlisted
      )
      try Idea.insert { Idea.Draft(existingIdea) }.execute(db)
      try TripIdea.insert { TripIdea.Draft(existingStop) }.execute(db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Restaurant ND 122\",\"place_notes\":\"Keep the reservation note.\"}]}")
      var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [existingStop], ideasByID: [existingIdea.id: existingIdea],
        stays: [], tripRegions: [], partyRegions: [], poolIdeas: [existingIdea]
      ))
      plan.places[0].existingTripIdeaID = nil
      plan.places[0].include = true
      plan.places[0].poolMatch = .none
      plan.places[0].matchConfirmed = true
      let mapPlace = Place(
        id: UUID(), name: "Restaurant ND 122", latitude: 55, longitude: 9,
        mapItemIdentifier: "maps.nd122"
      )
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )

      let result = try SeedPlan.commit(
        plan, tripID: trip.id, session: session, now: date.now,
        mapCaptures: [plan.places[0].id: mapPlace.ideaCapture()], in: db
      )

      let imported = try #require(try TripIdea.where { $0.tripID.eq(trip.id) && $0.id.neq(existingStop.id) }.fetchOne(db))
      #expect(result.mapRowOutcomes == [SeedMapRowOutcome(
        rowID: plan.places[0].id,
        rowTitle: "Restaurant ND 122",
        resolution: .collision(existingTitle: "Restaurant ND122")
      )])
      #expect(imported.ideaID == nil)
      #expect(imported.inlineTitle == "Restaurant ND 122")
      #expect(imported.inlineNote?.contains("About the place: Keep the reservation note.") == true)
      #expect(try TripIdea.find(existingStop.id).fetchOne(db)?.ideaID == existingIdea.id)
    }
  }

  @Test func detachedSavedSeedRowStillResolvesInTripPlanByItsTitle() async throws {
    try await database.write { db in
      let party = try TravelParty.ensureDefault(in: db)
      let trip = try Trip.create(name: "Denmark", in: db)
      let idea = Idea(id: UUID(), name: "Dyvig Badehotel", travelPartyID: party.id)
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Dyvig Badehotel\"}]}")
      var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [idea.id: idea], stays: [],
        tripRegions: [], partyRegions: [], poolIdeas: [idea]
      ))
      plan.places[0].matchConfirmed = true
      plan.places[0].confirmedIdeaID = idea.id
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      _ = try SeedPlan.commit(plan, tripID: trip.id, session: session, now: date.now, in: db)
      let linked = try #require(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db))
      #expect(linked.ideaID == idea.id)

      _ = try TripIdea.detachResolvedIdea(from: linked.id, in: db)
      let detached = try #require(try TripIdea.find(linked.id).fetchOne(db))
      #expect(detached.ideaID == nil)
      #expect(detached.inlineTitle == "Dyvig Badehotel")
      let resolved = TripPlan(entries: [detached], ideasByID: [:], lengthInDays: 7).stop(id: detached.id)
      #expect(resolved?.content == .freeform(title: "Dyvig Badehotel", note: nil, coordinate: nil))
    }
  }

  @Test func alreadyShortlistedND122SeedRowIsShownAndLeftUntouched() async throws {
    try await database.write { db in
      let party = try TravelParty.ensureDefault(in: db)
      let trip = try Trip.create(name: "Denmark", in: db)
      let idea = Idea(id: UUID(), name: "Restaurant ND122", travelPartyID: party.id)
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      let existing = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: idea.id, inlineTitle: nil, status: .shortlisted,
        shortlistRank: 4
      )
      try TripIdea.insert { TripIdea.Draft(existing) }.execute(db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Restaurant ND122\",\"verdict\":\"core\"}]}")
      let plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [existing], ideasByID: [idea.id: idea], stays: [],
        tripRegions: [], partyRegions: [], poolIdeas: [idea]
      ))
      let row = try #require(plan.places.first)
      #expect(row.alreadyOnTrip)
      #expect(!row.include)
      #expect(row.existingTripTitle == "Restaurant ND122")
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )

      _ = try SeedPlan.commit(plan, tripID: trip.id, session: session, now: date.now, in: db)

      #expect(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db) == 1)
      let unchanged = try #require(try TripIdea.find(existing.id).fetchOne(db))
      #expect(unchanged.status == .shortlisted)
      #expect(unchanged.shortlistRank == 4)
      #expect(unchanged.ideaID == idea.id)
    }
  }

  @Test func unresolvedConfirmedMapRowKeepsPlaceNotesAndIsReported() async throws {
    try await database.write { db in
      let trip = try Trip.create(name: "Denmark", in: db)
      let seed = try SeedReturn.decode("GV-SEED\n{\"places\":[{\"name\":\"Unresolved stay\",\"place_notes\":\"Keep this fact.\"}]}")
      var plan = SeedPlan.make(from: seed, trip: trip, context: SeedPlanContext(
        trip: trip, tripIdeas: [], ideasByID: [:], stays: [], tripRegions: [], partyRegions: []
      ))
      plan.places[0].matchConfirmed = true
      let session = HandoffSession(
        sourceType: "trip", sourceID: trip.id, taskType: RecommendationHandoffTask.seedTrip,
        scopeKey: nil, exportedPrompt: ""
      )
      let result = try SeedPlan.commit(
        plan, tripID: trip.id, session: session, now: date.now, in: db
      )
      let row = try #require(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db))
      #expect(row.ideaID == nil)
      #expect(row.inlineNote?.contains("About the place: Keep this fact.") == true)
      #expect(result.mapRowOutcomes == [SeedMapRowOutcome(
        rowID: plan.places[0].id, rowTitle: "Unresolved stay", resolution: .unresolved
      )])
    }
  }
}
