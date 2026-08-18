import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

extension TripPlanningModel {
  func beginAlternativeGroupLabelEdit(_ groupID: UUID) {
    editingAlternativeGroupID = groupID
    alternativeGroupLabelDraft = allAlternativeGroups
      .first { $0.id == groupID && $0.tripID == tripID }?
      .label ?? ""
  }

  func saveAlternativeGroupLabel() {
    guard let groupID = editingAlternativeGroupID else { return }
    _ = withErrorReporting {
      try database.write { db in
        try TripAlternativeGroup.rename(
          groupID: groupID,
          tripID: tripID,
          label: alternativeGroupLabelDraft,
          in: db)
      }
    }
    editingAlternativeGroupID = nil
    alternativeGroupLabelDraft = ""
  }

  func cancelAlternativeGroupLabelEdit() {
    editingAlternativeGroupID = nil
    alternativeGroupLabelDraft = ""
  }
}
