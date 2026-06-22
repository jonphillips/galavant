import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI

@Observable
@MainActor
final class TravelProfileEditModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database

  let travelPartyID: TravelParty.ID
  let plannerID: Planner.ID?

  var sharedDraft = ""
  var overlayDraft = ""

  init(travelPartyID: TravelParty.ID, plannerID: Planner.ID? = nil) {
    self.travelPartyID = travelPartyID
    self.plannerID = plannerID
  }

  func load() async {
    guard let profiles = try? await database.read({ db in
      try TravelProfile.where { $0.travelPartyID.eq(travelPartyID) }.fetchAll(db)
    }) else { return }
    sharedDraft = profiles.first { $0.plannerID == nil }?.preferences ?? ""
    if let plannerID {
      overlayDraft = profiles.first { $0.plannerID == plannerID }?.preferences ?? ""
    }
  }

  func saveButtonTapped() {
    let (partyID, plannerID, shared, overlay) =
      (travelPartyID, self.plannerID, sharedDraft, overlayDraft)
    withErrorReporting {
      try database.write { db in
        try TravelProfile.setPreferences(shared, travelPartyID: partyID, in: db)
        if let plannerID {
          try TravelProfile.setPreferences(
            overlay, travelPartyID: partyID, plannerID: plannerID, in: db)
        }
      }
    }
  }
}
