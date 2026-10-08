import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct SettingsModelTests {
  @Dependency(\.defaultDatabase) private var database

  @Test @MainActor
  func refreshTravelProfileUsesLowestIDSharedRow() async throws {
    let partyID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    let sharedLow = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    let sharedHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
    try await database.write { db in
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
}
