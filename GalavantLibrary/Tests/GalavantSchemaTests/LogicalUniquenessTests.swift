import CustomDump
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite struct LogicalUniquenessTests {
  @Test func keepsTheLowestIDForEachLogicalKey() {
    let winner = LogicalRow(id: UUID(-1), key: "duplicate")
    let loser = LogicalRow(id: UUID(-2), key: "duplicate")
    let unique = LogicalRow(id: UUID(-3), key: "unique")

    let converged = [loser, unique, winner].convergingByKey(\.key)

    expectNoDifference(converged.survivors, [winner, unique])
    expectNoDifference(converged.losers, [loser])
  }

  @Test func survivorSelectionIsIndependentOfInputOrder() {
    let winner = LogicalRow(id: UUID(-10), key: "duplicate")
    let loser = LogicalRow(id: UUID(-11), key: "duplicate")
    let unique = LogicalRow(id: UUID(-12), key: "unique")
    let expectedSurvivorIDs: Set<UUID> = [winner.id, unique.id]

    for rows in [
      [winner, loser, unique],
      [loser, winner, unique],
      [unique, loser, winner],
    ] {
      expectNoDifference(Set(rows.convergingByKey(\.key).survivors.map(\.id)), expectedSurvivorIDs)
    }
  }

  @Test func uniqueInputIsPreserved() {
    let rows = [
      LogicalRow(id: UUID(-20), key: "first"),
      LogicalRow(id: UUID(-21), key: "second"),
    ]

    let converged = rows.convergingByKey(\.key)

    expectNoDifference(converged.survivors, rows)
    expectNoDifference(converged.losers, [])
  }
}

private struct LogicalRow: Identifiable, Equatable {
  let id: UUID
  let key: String
}

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct IdeaInterestConvergenceTests {
  @Dependency(\.defaultDatabase) var database

  @Test func standingReadCountsEachPlannerOnceWithoutDeletingDuplicates() throws {
    let ideaID = UUID(-100)
    let plannerID = UUID(-101)

    try database.write { db in
      try seedPartyIdeaAndPlanner(
        partyID: UUID(-102), ideaID: ideaID, plannerID: plannerID, in: db
      )
      try IdeaInterest.insert {
        IdeaInterest.Draft(
          IdeaInterest(
            id: UUID(-110), ideaID: ideaID, plannerID: plannerID, level: .mustDo
          )
        )
      }
      .execute(db)
      try IdeaInterest.insert {
        IdeaInterest.Draft(
          IdeaInterest(
            id: UUID(-111), ideaID: ideaID, plannerID: plannerID, level: .wantToDo
          )
        )
      }
      .execute(db)
    }

    let result = try database.read { db in
      let beforeCount = try IdeaInterest.where { $0.ideaID.eq(ideaID) }.fetchCount(db)
      let interests = try IdeaInterest.where { $0.ideaID.eq(ideaID) }.fetchAll(db)
      let survivors = interests
        .convergingByKey { [$0.ideaID, $0.plannerID] }
        .survivors
      let standing = Interest.standing(survivors.map(\.level))
      let afterCount = try IdeaInterest.where { $0.ideaID.eq(ideaID) }.fetchCount(db)
      return (beforeCount, standing, afterCount)
    }

    expectNoDifference(result.0, 2)
    expectNoDifference(result.1, .neutral)
    expectNoDifference(result.2, 2)
  }

  @Test func setKeepsLowestIDsRegardlessOfInsertionOrderAndPreservesNotes() throws {
    let firstIdeaID = UUID(-200)
    let secondIdeaID = UUID(-201)
    let plannerID = UUID(-202)
    let firstWinnerID = UUID(-210)
    let firstLoserID = UUID(-211)
    let secondWinnerID = UUID(-220)
    let secondLoserID = UUID(-221)

    try database.write { db in
      let partyID = UUID(-203)
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID)) }.execute(db)
      for ideaID in [firstIdeaID, secondIdeaID] {
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Seeded", travelPartyID: partyID)
        }
        .execute(db)
      }
      try Planner.insert {
        Planner.Draft(Planner(id: plannerID, displayName: "Planner", travelPartyID: partyID))
      }
      .execute(db)

      // Winner first for one key, loser first for the other: fetch order must not
      // influence the survivor.
      for interest in [
        IdeaInterest(
          id: firstWinnerID, ideaID: firstIdeaID, plannerID: plannerID,
          level: .wantToDo, note: "Window seat"
        ),
        IdeaInterest(
          id: firstLoserID, ideaID: firstIdeaID, plannerID: plannerID,
          level: .couldDo, note: "Ask about the tasting menu"
        ),
        IdeaInterest(
          id: secondLoserID, ideaID: secondIdeaID, plannerID: plannerID,
          level: .wantToDo
        ),
        IdeaInterest(
          id: secondWinnerID, ideaID: secondIdeaID, plannerID: plannerID,
          level: .couldDo
        ),
      ] {
        try IdeaInterest.insert { IdeaInterest.Draft(interest) }.execute(db)
      }

      try IdeaInterest.set(
        level: .mustDo, ideaID: firstIdeaID, plannerID: plannerID, in: db
      )
      try IdeaInterest.set(
        level: .mustDo, ideaID: secondIdeaID, plannerID: plannerID, in: db
      )
    }

    let rows = try database.read { db in
      try IdeaInterest.fetchAll(db).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    expectNoDifference(rows.map(\.id), [firstWinnerID, secondWinnerID])
    expectNoDifference(rows.map(\.level), [.mustDo, .mustDo])
    expectNoDifference(
      rows.map(\.note),
      ["Window seat\n\nAsk about the tasting menu", ""]
    )
  }

  private func seedPartyIdeaAndPlanner(
    partyID: TravelParty.ID,
    ideaID: Idea.ID,
    plannerID: Planner.ID,
    in db: Database
  ) throws {
    try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID)) }.execute(db)
    try Idea.insert {
      Idea.Draft(id: ideaID, name: "Seeded", travelPartyID: partyID)
    }
    .execute(db)
    try Planner.insert {
      Planner.Draft(Planner(id: plannerID, displayName: "Planner", travelPartyID: partyID))
    }
    .execute(db)
  }
}

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct AssociationConvergenceTests {
  @Dependency(\.defaultDatabase) var database

  @Test func ideaTagAddCleansSeededDuplicatesAndKeepsTheLowestID() throws {
    let partyID = UUID(-300)
    let ideaID = UUID(-301)
    let tagID = UUID(-302)
    let winnerID = UUID(-310)
    let loserID = UUID(-311)

    try database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID)) }.execute(db)
      try Idea.insert {
        Idea.Draft(id: ideaID, name: "Seeded", travelPartyID: partyID)
      }
      .execute(db)
      try GalavantSchema.Tag.insert {
        GalavantSchema.Tag.Draft(
          GalavantSchema.Tag(id: tagID, name: "Michelin", travelPartyID: partyID)
        )
      }
      .execute(db)
      for id in [loserID, winnerID] {
        try IdeaTag.insert {
          IdeaTag.Draft(IdeaTag(id: id, ideaID: ideaID, tagID: tagID))
        }
        .execute(db)
      }

      try IdeaTag.add(tagID: tagID, to: ideaID, in: db)
    }

    let rows = try database.read { db in try IdeaTag.fetchAll(db) }
    expectNoDifference(rows.map(\.id), [winnerID])
  }

  @Test func tripRegionSetCleansSeededDuplicatesAndKeepsTheLowestID() throws {
    let partyID = UUID(-400)
    let tripID = UUID(-401)
    let regionID = UUID(-402)
    let winnerID = UUID(-410)
    let loserID = UUID(-411)

    try database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID)) }.execute(db)
      try Trip.insert {
        Trip.Draft(Trip(id: tripID, name: "Seeded", travelPartyID: partyID))
      }
      .execute(db)
      try MapRegion.insert {
        MapRegion.Draft(
          MapRegion(
            id: regionID,
            name: "Copenhagen",
            centerLatitude: 55.6761,
            centerLongitude: 12.5683,
            latitudeDelta: 0.2,
            longitudeDelta: 0.2,
            travelPartyID: partyID
          )
        )
      }
      .execute(db)
      for id in [loserID, winnerID] {
        try TripRegion.insert {
          TripRegion.Draft(TripRegion(id: id, tripID: tripID, regionID: regionID))
        }
        .execute(db)
      }

      try TripRegion.setRegions([regionID], forTrip: tripID, in: db)
    }

    let rows = try database.read { db in try TripRegion.fetchAll(db) }
    expectNoDifference(rows.map(\.id), [winnerID])
  }
}

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TravelPartyConvergenceTests {
  @Dependency(\.defaultDatabase) var database

  @Test func populatedPartyWinsEvenWhenTheEmptyPartyHasTheLowerID() throws {
    let emptyPartyID = UUID(-500)
    let populatedPartyID = UUID(-501)

    let result = try database.write { db in
      try TravelParty.insert {
        TravelParty.Draft(TravelParty(id: emptyPartyID, name: "Empty"))
      }
      .execute(db)
      try TravelParty.insert {
        TravelParty.Draft(TravelParty(id: populatedPartyID, name: "Shared"))
      }
      .execute(db)
      try Planner.insert {
        Planner.Draft(
          Planner(id: UUID(-502), displayName: "Planner", travelPartyID: populatedPartyID)
        )
      }
      .execute(db)

      return try TravelParty.ensureDefault(in: db)
    }

    let parties = try database.read { db in try TravelParty.fetchAll(db) }
    expectNoDifference(result.id, populatedPartyID)
    expectNoDifference(parties.map(\.id), [populatedPartyID])
  }

  @Test func repointsEveryDirectChildBeforeDeletingAPopulatedLoser() throws {
    let survivorID = UUID(-600)
    let loserID = UUID(-601)
    let plannerID = UUID(-610)
    let ideaID = UUID(-611)
    let regionID = UUID(-612)
    let tagID = UUID(-613)
    let tripID = UUID(-614)

    let result = try database.write { db in
      try TravelParty.insert {
        TravelParty.Draft(TravelParty(id: survivorID, name: "Survivor"))
      }
      .execute(db)
      try TravelParty.insert {
        TravelParty.Draft(TravelParty(id: loserID, name: "Loser"))
      }
      .execute(db)
      // Both parties are populated, so the stable lowest-id fallback applies.
      try Planner.insert {
        Planner.Draft(
          Planner(id: UUID(-609), displayName: "Existing", travelPartyID: survivorID)
        )
      }
      .execute(db)
      try Planner.insert {
        Planner.Draft(Planner(id: plannerID, displayName: "Moved", travelPartyID: loserID))
      }
      .execute(db)
      try Idea.insert {
        Idea.Draft(id: ideaID, name: "Moved", travelPartyID: loserID)
      }
      .execute(db)
      try MapRegion.insert {
        MapRegion.Draft(
          MapRegion(
            id: regionID,
            name: "Moved",
            centerLatitude: 55.6761,
            centerLongitude: 12.5683,
            latitudeDelta: 0.2,
            longitudeDelta: 0.2,
            travelPartyID: loserID
          )
        )
      }
      .execute(db)
      try GalavantSchema.Tag.insert {
        GalavantSchema.Tag.Draft(
          GalavantSchema.Tag(id: tagID, name: "Moved", travelPartyID: loserID)
        )
      }
      .execute(db)
      try Trip.insert {
        Trip.Draft(Trip(id: tripID, name: "Moved", travelPartyID: loserID))
      }
      .execute(db)
      try IdeaEvaluation.insert {
        IdeaEvaluation.Draft(
          IdeaEvaluation(
            id: UUID(-615),
            travelPartyID: loserID,
            ideaID: ideaID,
            sourceName: "Guide",
            kind: .text,
            nativeValueText: "Recommended",
            nativeDisplay: "Recommended",
            recordedAt: Date(timeIntervalSinceReferenceDate: 0),
            confidence: .manual,
            staleness: .current
          )
        )
      }
      .execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(
          TravelProfile(id: UUID(-616), travelPartyID: loserID, preferences: "Moved")
        )
      }
      .execute(db)

      // Downstream rows prove repointing their direct Idea/Trip parents keeps the
      // complete graph alive through loser-party deletion.
      try IdeaInterest.insert {
        IdeaInterest.Draft(
          IdeaInterest(
            id: UUID(-620), ideaID: ideaID, plannerID: plannerID, level: .mustDo
          )
        )
      }
      .execute(db)
      try IdeaTag.insert {
        IdeaTag.Draft(IdeaTag(id: UUID(-621), ideaID: ideaID, tagID: tagID))
      }
      .execute(db)
      try TripRegion.insert {
        TripRegion.Draft(TripRegion(id: UUID(-622), tripID: tripID, regionID: regionID))
      }
      .execute(db)

      return try TravelParty.ensureDefault(in: db)
    }

    let snapshot = try database.read { db in
      (
        parties: try TravelParty.fetchAll(db).map(\.id),
        plannerPartyIDs: try Planner.fetchAll(db).compactMap(\.travelPartyID),
        ideaPartyIDs: try Idea.fetchAll(db).compactMap(\.travelPartyID),
        regionPartyIDs: try MapRegion.fetchAll(db).compactMap(\.travelPartyID),
        tagPartyIDs: try GalavantSchema.Tag.fetchAll(db).compactMap(\.travelPartyID),
        tripPartyIDs: try Trip.fetchAll(db).compactMap(\.travelPartyID),
        evaluationPartyIDs: try IdeaEvaluation.fetchAll(db).map(\.travelPartyID),
        profilePartyIDs: try TravelProfile.fetchAll(db).map(\.travelPartyID),
        interestCount: try IdeaInterest.fetchCount(db),
        ideaTagCount: try IdeaTag.fetchCount(db),
        tripRegionCount: try TripRegion.fetchCount(db)
      )
    }

    expectNoDifference(result.id, survivorID)
    expectNoDifference(snapshot.parties, [survivorID])
    expectNoDifference(snapshot.plannerPartyIDs, [survivorID, survivorID])
    expectNoDifference(snapshot.ideaPartyIDs, [survivorID])
    expectNoDifference(snapshot.regionPartyIDs, [survivorID])
    expectNoDifference(snapshot.tagPartyIDs, [survivorID])
    expectNoDifference(snapshot.tripPartyIDs, [survivorID])
    expectNoDifference(snapshot.evaluationPartyIDs, [survivorID])
    expectNoDifference(snapshot.profilePartyIDs, [survivorID])
    expectNoDifference(snapshot.interestCount, 1)
    expectNoDifference(snapshot.ideaTagCount, 1)
    expectNoDifference(snapshot.tripRegionCount, 1)
  }
}
