import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

/// `TravelProfile` is the editable taste description (ADR-0015 §3). DB-based tests
/// verify the upsert ops round-trip correctly; pure tests exercise the assembly helper.
@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TravelProfileTests {
  @Dependency(\.defaultDatabase) var database

  // MARK: - Shared profile

  @Test func sharedProfileRoundTrip() async throws {
    let (partyID, text) = try await database.write { db -> (TravelParty.ID, String) in
      let partyID = try TravelParty.ensureDefault(in: db).id
      try TravelProfile.setPreferences(
        "Luxury, high-end dining, low-friction",
        travelPartyID: partyID, in: db)
      return (partyID, "Luxury, high-end dining, low-friction")
    }
    let profiles = try await database.read { db in
      try TravelProfile.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
    }
    #expect(profiles.count == 1)
    #expect(profiles[0].plannerID == nil)
    #expect(profiles[0].preferences == text)
  }

  @Test func settingSharedProfileAgainReplacesNotDuplicates() async throws {
    let partyID = try await database.write { db -> TravelParty.ID in
      let partyID = try TravelParty.ensureDefault(in: db).id
      try TravelProfile.setPreferences("First draft", travelPartyID: partyID, in: db)
      try TravelProfile.setPreferences("Revised text", travelPartyID: partyID, in: db)
      return partyID
    }
    let profiles = try await database.read { db in
      try TravelProfile.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
    }
    #expect(profiles.count == 1)
    #expect(profiles[0].preferences == "Revised text")
  }

  // MARK: - Per-planner overlay

  @Test func perPlannerOverlayRoundTrip() async throws {
    let (partyID, plannerID) = try await database.write { db -> (TravelParty.ID, Planner.ID) in
      let partyID = try TravelParty.ensureDefault(in: db).id
      let plannerID = try seedPlanner(displayName: "Jon", partyID: partyID, in: db)
      try TravelProfile.setPreferences(
        "Shared: luxury, high-end dining",
        travelPartyID: partyID, in: db)
      try TravelProfile.setPreferences(
        "Jon overlay: skews Michelin dining",
        travelPartyID: partyID, plannerID: plannerID, in: db)
      return (partyID, plannerID)
    }
    let profiles = try await database.read { db in
      try TravelProfile.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
    }
    #expect(profiles.count == 2)
    let shared = profiles.first { $0.plannerID == nil }
    let overlay = profiles.first { $0.plannerID == plannerID }
    #expect(shared?.preferences == "Shared: luxury, high-end dining")
    #expect(overlay?.preferences == "Jon overlay: skews Michelin dining")
  }

  @Test func settingOverlayAgainReplacesNotDuplicates() async throws {
    let (partyID, plannerID) = try await database.write { db -> (TravelParty.ID, Planner.ID) in
      let partyID = try TravelParty.ensureDefault(in: db).id
      let plannerID = try seedPlanner(displayName: "Jon", partyID: partyID, in: db)
      try TravelProfile.setPreferences("First", travelPartyID: partyID, plannerID: plannerID, in: db)
      try TravelProfile.setPreferences("Second", travelPartyID: partyID, plannerID: plannerID, in: db)
      return (partyID, plannerID)
    }
    let profiles = try await database.read { db in
      try TravelProfile
        .where { $0.travelPartyID.eq(partyID) && $0.plannerID.eq(plannerID) }
        .fetchAll(db)
    }
    #expect(profiles.count == 1)
    #expect(profiles[0].preferences == "Second")
  }

  // MARK: - removeProfile

  @Test func removeProfileDeletesTheRow() async throws {
    let partyID = try await database.write { db -> TravelParty.ID in
      let partyID = try TravelParty.ensureDefault(in: db).id
      try TravelProfile.setPreferences("Will be removed", travelPartyID: partyID, in: db)
      try TravelProfile.removeProfile(travelPartyID: partyID, in: db)
      return partyID
    }
    let count = try await database.read { db in
      try TravelProfile.where { $0.travelPartyID.eq(partyID) }.fetchCount(db)
    }
    #expect(count == 0)
  }

  @Test func removeProfileNoopsWhenAbsent() async throws {
    let partyID = try await database.write { db -> TravelParty.ID in
      try TravelParty.ensureDefault(in: db).id
    }
    // Should not throw even when the row doesn't exist.
    try await database.write { db in
      try TravelProfile.removeProfile(travelPartyID: partyID, in: db)
    }
  }

  // MARK: - promptLines (pure)

  @Test func promptLinesRenderSharedProfileAndOverlaysInDisplayNameOrder() {
    let partyID = UUID()
    let jon = Planner(id: UUID(), displayName: "Jon", travelPartyID: partyID)
    let wife = Planner(id: UUID(), displayName: "Wife", travelPartyID: partyID)
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: wife.id,
                    preferences: "  values relaxed pace \n"),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: nil,
                    preferences: "  Luxury, high-end dining  "),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: jon.id,
                    preferences: "Michelin dining"),
      TravelProfile(id: UUID(), travelPartyID: UUID(), plannerID: nil,
                    preferences: "Other household"),
    ]

    #expect(TravelProfile.promptLines(
      travelPartyID: partyID, profiles: profiles, planners: [wife, jon]
    ) == [
      "Our travel taste: Luxury, high-end dining",
      "Jon's taste: Michelin dining",
      "Wife's taste: values relaxed pace",
    ])
  }

  @Test func promptLinesRenderSharedProfileWithoutOverlays() {
    let partyID = UUID()
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, preferences: "Shared taste")
    ]
    #expect(TravelProfile.promptLines(
      travelPartyID: partyID, profiles: profiles, planners: []
    ) == ["Our travel taste: Shared taste"])
  }

  @Test func promptLinesChooseLowestIDForDuplicateSharedAndPlannerRows() {
    let partyID = UUID()
    let plannerID = UUID()
    let planner = Planner(id: plannerID, displayName: "Jon", travelPartyID: partyID)
    let sharedLow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let sharedHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let overlayLow = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let overlayHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let profiles = [
      TravelProfile(id: sharedHigh, travelPartyID: partyID, preferences: "Shared high"),
      TravelProfile(id: overlayHigh, travelPartyID: partyID, plannerID: plannerID,
                    preferences: "Overlay high"),
      TravelProfile(id: sharedLow, travelPartyID: partyID, preferences: "Shared low"),
      TravelProfile(id: overlayLow, travelPartyID: partyID, plannerID: plannerID,
                    preferences: "Overlay low"),
    ]

    #expect(TravelProfile.promptLines(
      travelPartyID: partyID, profiles: profiles, planners: [planner]
    ) == ["Our travel taste: Shared low", "Jon's taste: Overlay low"])
  }

  @Test func promptLinesRenderOverlayOnlyAndSkipOrphansAndWhitespace() {
    let partyID = UUID()
    let planner = Planner(id: UUID(), displayName: "Jon", travelPartyID: partyID)
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: planner.id,
                    preferences: "  personal skew  "),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: UUID(),
                    preferences: "orphaned overlay"),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: nil,
                    preferences: " \n "),
    ]

    #expect(TravelProfile.promptLines(
      travelPartyID: partyID, profiles: profiles, planners: [planner]
    ) == ["Jon's taste: personal skew"])
  }

  @Test func promptLinesReturnEmptyWhenAllPreferencesAreEmpty() {
    let partyID = UUID()
    let planner = Planner(id: UUID(), displayName: "Jon", travelPartyID: partyID)
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: nil, preferences: " \n "),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: planner.id, preferences: "\t"),
    ]

    #expect(TravelProfile.promptLines(
      travelPartyID: partyID, profiles: profiles, planners: [planner]
    ).isEmpty)
  }

  @Test func setPreferencesConvergesDuplicateHouseholdAndPlannerRows() async throws {
    let partyID = UUID()
    let plannerID = UUID()
    let sharedLow = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let sharedHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let overlayLow = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    let overlayHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!

    try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID)) }.execute(db)
      try Planner.insert {
        Planner.Draft(id: plannerID, displayName: "Jon", travelPartyID: partyID)
      }.execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(TravelProfile(id: sharedHigh, travelPartyID: partyID, preferences: "Old shared high"))
      }.execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(TravelProfile(id: sharedLow, travelPartyID: partyID, preferences: "Old shared low"))
      }.execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(TravelProfile(
          id: overlayHigh, travelPartyID: partyID, plannerID: plannerID, preferences: "Old overlay high"))
      }.execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(TravelProfile(
          id: overlayLow, travelPartyID: partyID, plannerID: plannerID, preferences: "Old overlay low"))
      }.execute(db)

      #expect(try TravelProfile.setPreferences("Updated shared", travelPartyID: partyID, in: db) == sharedLow)
      #expect(try TravelProfile.setPreferences(
        "Updated overlay", travelPartyID: partyID, plannerID: plannerID, in: db) == overlayLow)
    }

    let profiles = try await database.read { db in
      try TravelProfile.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
    }
    #expect(profiles.count == 2)
    #expect(Set(profiles.map(\.id)) == [sharedLow, overlayLow])
    #expect(profiles.first { $0.id == sharedLow }?.preferences == "Updated shared")
    #expect(profiles.first { $0.id == overlayLow }?.preferences == "Updated overlay")
  }

  // MARK: - Helpers

  private func seedPlanner(
    displayName: String, partyID: TravelParty.ID, in db: Database
  ) throws -> Planner.ID {
    let id = UUID()
    try Planner.insert {
      Planner.Draft(id: id, displayName: displayName, travelPartyID: partyID)
    }.execute(db)
    return id
  }
}
