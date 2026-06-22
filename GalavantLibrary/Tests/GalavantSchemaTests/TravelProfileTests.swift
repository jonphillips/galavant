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

  // MARK: - assembledProfile (pure)

  @Test func assembledProfileCombinesSharedAndOverlay() {
    let partyID = UUID()
    let plannerID = UUID()
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: nil,
                    preferences: "Luxury, high-end dining"),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: plannerID,
                    preferences: "Skews Michelin dining"),
    ]
    let assembled = TravelProfile.assembledProfile(
      travelPartyID: partyID, plannerID: plannerID, from: profiles)
    #expect(assembled.contains("Luxury, high-end dining"))
    #expect(assembled.contains("Skews Michelin dining"))
  }

  @Test func assembledProfileNilPlannerReturnsSharedOnly() {
    let partyID = UUID()
    let plannerID = UUID()
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: nil,
                    preferences: "Shared text"),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: plannerID,
                    preferences: "Jon overlay"),
    ]
    let assembled = TravelProfile.assembledProfile(
      travelPartyID: partyID, plannerID: nil, from: profiles)
    #expect(assembled == "Shared text")
    #expect(!assembled.contains("Jon overlay"))
  }

  @Test func assembledProfileIgnoresOtherParties() {
    let myParty = UUID()
    let otherParty = UUID()
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: otherParty, plannerID: nil,
                    preferences: "Other party's text"),
    ]
    let assembled = TravelProfile.assembledProfile(
      travelPartyID: myParty, plannerID: nil, from: profiles)
    #expect(assembled.isEmpty)
  }

  @Test func assembledProfileSkipsEmptyParts() {
    let partyID = UUID()
    let plannerID = UUID()
    let profiles = [
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: nil, preferences: ""),
      TravelProfile(id: UUID(), travelPartyID: partyID, plannerID: plannerID,
                    preferences: "Overlay only"),
    ]
    let assembled = TravelProfile.assembledProfile(
      travelPartyID: partyID, plannerID: plannerID, from: profiles)
    #expect(assembled == "Overlay only")
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
