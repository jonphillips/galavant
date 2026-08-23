import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Alternative itinerary actions for the planning model.
extension TripPlanningModel {
  func addAlternativeButtonTapped(to stopID: TripIdea.ID) {
    destination = .alternativeSource(AlternativeSourceTarget(targetStopID: stopID))
  }

  func addAsAlternativeButtonTapped(sourceStopID: TripIdea.ID) {
    destination = .alternativeSlot(AlternativeSlotTarget(sourceStopID: sourceStopID))
  }

  func addCustomAlternativeButtonTapped(to targetStopID: TripIdea.ID) {
    destination = .freeformStop(FreeformStopDraft(alternativeToStopID: targetStopID))
  }

  func shortlistAlternativeSelected(_ sourceStopID: TripIdea.ID, for targetStopID: TripIdea.ID) {
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.addAlternative(sourceStopID: sourceStopID, to: targetStopID, in: db)
      }
    }
    destination = nil
  }

  func alternativeSlotSelected(_ targetStopID: TripIdea.ID, for sourceStopID: TripIdea.ID) {
    shortlistAlternativeSelected(sourceStopID, for: targetStopID)
  }

  func cycleAlternativeButtonTapped(_ stopID: TripIdea.ID) {
    var activeID: TripIdea.ID?
    _ = withErrorReporting {
      activeID = try database.write { db in
        try TripIdea.cycleAlternative(stopID: stopID, in: db)
      }
    }
    if let activeID { selectStop(activeID) }
  }

  func alternativeButtonTapped(_ stopID: TripIdea.ID) {
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.setActiveAlternative(stopID: stopID, in: db)
      }
    }
    selectStop(stopID)
  }

  func promoteAlternativeButtonTapped(_ stopID: TripIdea.ID) {
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.promoteAlternative(stopID: stopID, in: db)
      }
    }
    selectStop(stopID)
  }

  func toggleAlternativeDisclosure(_ groupID: UUID) {
    if expandedAlternativeGroupIDs.contains(groupID) {
      expandedAlternativeGroupIDs.remove(groupID)
    } else {
      expandedAlternativeGroupIDs.insert(groupID)
    }
  }

  func isAlternativeDisclosureExpanded(_ groupID: UUID) -> Bool {
    expandedAlternativeGroupIDs.contains(groupID)
  }

  func alternativesAreVisible(for ring: ResolvedAlternativeRing) -> Bool {
    isAlternativeDisclosureExpanded(ring.groupID) || canvasSelectedStopID == ring.activeMember.id
  }
}
