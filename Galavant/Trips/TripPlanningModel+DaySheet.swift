import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// A day's "+" sheet (`PlaceIdeaSheet`): the day's one-line purpose note, and the
/// custom-stop / lodging editors it hands off to once it has dismissed.
extension TripPlanningModel {
  /// From a day's "+" sheet: author a new freeform stop ("lunch", "train to
  /// Aarhus") landing on that day, or in the To-Be-Scheduled bucket for `nil`; the
  /// editor's day picker can still move it (ADR-0010).
  func addCustomStop(onDay day: Int?) {
    queueAfterPlaceIdeaSheet(.freeformStop(FreeformStopDraft(day: day)))
  }

  /// From a day's "+" sheet: add lodging checking in that day, for one night to
  /// start (the editor widens the span). The last day can't be a check-in, so it
  /// checks in the night before.
  func addLodging(checkingInOn day: Int) {
    let length = max(2, trip?.lengthInDays ?? 2)
    let checkIn = min(max(day, 1), length - 1)
    queueAfterPlaceIdeaSheet(.stay(StayDraft(checkInDay: checkIn, checkOutDay: checkIn + 1)))
  }

  private func queueAfterPlaceIdeaSheet(_ next: Destination) {
    queuedDestination = next
    destination = nil
  }

  /// The day's "+" sheet finished dismissing — present whatever it queued.
  func placeIdeaSheetDismissed() {
    guard let next = queuedDestination else { return }
    queuedDestination = nil
    destination = next
  }

  /// The day's one-line purpose note ("Wine tasting in Beaune"), if any.
  func dayNote(forDay day: Int) -> String? {
    allTripDayNotes.first { $0.tripID == tripID && $0.dayNumber == day }?.note
  }

  /// Set (or, blank, clear) the day's purpose note. A no-op when unchanged, so
  /// dismissing the sheet doesn't write (and sync) an identical row.
  func setDayNote(_ note: String, forDay day: Int) {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != (dayNote(forDay: day) ?? "") else { return }
    let tripID = tripID
    withErrorReporting {
      try database.write { db in
        try TripDayNote.set(trimmed, forTrip: tripID, day: day, in: db)
      }
    }
  }
}
