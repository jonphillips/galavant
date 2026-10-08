import Dependencies
import GalavantSchema
import SQLiteData
import Sharing
import SwiftUI

@Observable
@MainActor
final class TravelProfileEditModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll(Planner.all) private var planners
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""

  let travelPartyID: TravelParty.ID
  var plannerID: Planner.ID? {
    guard let plannerID = UUID(uuidString: currentPlannerIDString),
      planners.contains(where: { $0.id == plannerID })
    else { return nil }
    return plannerID
  }

  var sharedDraft = ""
  var overlayDraft = ""

  init(travelPartyID: TravelParty.ID) {
    self.travelPartyID = travelPartyID
  }

  func load() async {
    guard let rows = try? await database.read({ db in
      try TravelProfile.where { $0.travelPartyID.eq(travelPartyID) }.fetchAll(db)
    }) else { return }
    let profiles = TravelProfile.survivingProfiles(travelPartyID: travelPartyID, profiles: rows)
    sharedDraft = profiles.first { $0.plannerID == nil }?.preferences ?? ""
    if let plannerID {
      overlayDraft = profiles.first { $0.plannerID == plannerID }?.preferences ?? ""
    } else {
      overlayDraft = ""
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

  var canEditOverlay: Bool { plannerID != nil }
}
