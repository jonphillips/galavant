import CoreLocation
import Foundation
import GalavantSchema
import SQLiteData

extension TripPlanningModel {
  /// Mirrors a coordinate edit from the sheet into the presentation destination
  /// so the canvas can show the unsaved pin while the editor remains open.
  func updateFreeformDraftCoordinate(_ coordinate: CLLocationCoordinate2D?) {
    guard case let .freeformStop(current) = destination else { return }
    var draft = current
    draft.coordinate = coordinate
    destination = .freeformStop(draft)
  }

  /// Commit the custom-stop editor: create a new stop (placed on its chosen day,
  /// or left in the bucket), or update the edited one's content. A blank title
  /// is dropped (the sheet's Save is disabled, but guard anyway).
  func saveFreeform(_ draft: FreeformStopDraft) {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, let tripID = trip?.id else { return }
    let trimmedNote = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    let note = trimmedNote.isEmpty ? nil : trimmedNote
    let canEditBooking = draft.stopID.map {
      calendarTimeAuthority(for: $0) == .manual
    } ?? true
    var savedStopID: TripIdea.ID?
    withErrorReporting {
      try database.write { db in
        if let stopID = draft.stopID {
          savedStopID = stopID
          try TripIdea.editFreeform(
            stopID: stopID,
            title: title,
            note: note,
            latitude: draft.coordinate?.latitude,
            longitude: draft.coordinate?.longitude,
            in: db)
        } else if let targetStopID = draft.alternativeToStopID {
          savedStopID = try TripIdea.addFreeformAlternative(
            title: title,
            note: note,
            latitude: draft.coordinate?.latitude,
            longitude: draft.coordinate?.longitude,
            to: targetStopID,
            in: db)
        } else {
          let id = try TripIdea.createFreeform(
            tripID: tripID,
            title: title,
            note: note,
            latitude: draft.coordinate?.latitude,
            longitude: draft.coordinate?.longitude,
            in: db)
          savedStopID = id
          if let day = draft.day {
            try TripIdea.schedule(.day(day), stopID: id, in: db)
          }
        }
        if canEditBooking, let savedStopID {
          try TripIdea.setBooking(
            reservationPin(from: draft.booking), stopID: savedStopID, in: db)
        }
      }
    }
    destination = nil
  }
}
