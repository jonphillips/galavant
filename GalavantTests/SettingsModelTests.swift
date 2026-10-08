import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Sharing
import Testing

@testable import Galavant

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct SettingsModelTests {
  @Dependency(\.defaultDatabase) private var database

  @Shared(.appStorage("currentPlannerID")) private var currentPlannerIDString = ""

  @Test @MainActor
  func refreshTravelProfileUsesLowestIDSharedRow() async throws {
    let partyID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    let sharedLow = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    let sharedHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
    _ = try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID)) }.execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(TravelProfile(
          id: sharedHigh, travelPartyID: partyID, preferences: "Wrong summary"))
      }.execute(db)
      try TravelProfile.insert {
        TravelProfile.Draft(TravelProfile(
          id: sharedLow, travelPartyID: partyID, preferences: "  First line\nSecond line  "))
      }.execute(db)
    }

    let model = SettingsModel()
    await model.refreshTravelProfile()

    #expect(model.travelPartyID == partyID)
    #expect(model.sharedTasteSummary == "First line")
  }

  @Test @MainActor
  func travelProfileEditorReadsCurrentPlannerAndItsOverlay() async throws {
    $currentPlannerIDString.withLock { $0 = "" }
    let partyID = try await database.write { db in
      try TravelParty.ensureDefault(in: db).id
    }
    let planner = try await database.write { db in
      try Planner.create(displayName: "Jon", in: db)
    }
    _ = try await database.write { db in
      try TravelProfile.setPreferences(
        "Prefers quiet hotels", travelPartyID: partyID, plannerID: planner.id, in: db)
    }

    let model = TravelProfileEditModel(travelPartyID: partyID)
    await model.load()
    #expect(model.canEditOverlay == false)

    $currentPlannerIDString.withLock { $0 = planner.id.uuidString }
    #expect(model.plannerID == planner.id)
    await model.load()
    #expect(model.canEditOverlay)
    #expect(model.overlayDraft == "Prefers quiet hotels")
  }

  @Test @MainActor
  func travelProfileEditorTreatsUnknownPlannerAsNoIdentity() async throws {
    let partyID = try await database.write { db in
      try TravelParty.ensureDefault(in: db).id
    }
    $currentPlannerIDString.withLock { $0 = UUID().uuidString }

    let model = TravelProfileEditModel(travelPartyID: partyID)
    await model.load()

    #expect(model.plannerID == nil)
    #expect(model.canEditOverlay == false)
  }

  @Test @MainActor
  func plannerManagementSetsDeviceIdentity() async throws {
    $currentPlannerIDString.withLock { $0 = "" }
    let planner = try await database.write { db in
      _ = try TravelParty.ensureDefault(in: db)
      return try Planner.create(displayName: "Wendy", in: db)
    }

    let model = PlannerManagementModel()
    model.setCurrentPlanner(planner)

    #expect(model.currentPlannerID == planner.id)
    #expect(currentPlannerIDString == planner.id.uuidString)
  }
}
