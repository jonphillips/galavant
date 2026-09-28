import Foundation
import GalavantSchema
import SQLiteData

extension TripPlanningModel {
  func bookingFields(for stop: ResolvedStop) -> BookingFieldsDraft {
    return BookingFieldsDraft(
      subject: .stop(canEditPin: calendarTimeAuthority(for: stop.id) == .manual),
      explicitStatus: stop.entry.bookingStatus,
      inferredStatus: BookingStatus.inferred(for: stop.idea?.kind),
      isPinned: stop.entry.pinnedDate != nil,
      date: stop.entry.pinnedDate
        ?? stop.entry.schedule.dayNumber.flatMap { trip?.date(forDay: $0) }
        ?? date(),
      confirmationNumber: stop.entry.confirmationNumber ?? "",
      bookingURL: stop.entry.bookingURL ?? "",
      partySize: stop.entry.partySize.map(String.init) ?? "")
  }

  func bookingFields(for stay: TripStay) -> BookingFieldsDraft {
    return BookingFieldsDraft(
      subject: .stay,
      explicitStatus: stay.bookingStatus,
      inferredStatus: .toBook,
      confirmationNumber: stay.confirmationNumber ?? "",
      bookingURL: stay.bookingURL ?? "")
  }

  func toggleBookingStatus(for stop: ResolvedStop) {
    let resolved = stop.entry.resolvedBooking(idea: stop.idea)
    guard let status = BookingStatus.quickAction(for: resolved) else { return }
    withErrorReporting {
      try database.write { db in
        try TripIdea.setBookingStatus(status, stopID: stop.id, in: db)
      }
    }
  }

  /// The To Book sheet's deliberately small writes use the same Slice 1 status
  /// operations as the editors; resolution remains entirely in `TripBookingRollup`.
  func setBookingStatus(_ status: BookingStatus, for row: TripBookingRow) {
    withErrorReporting {
      try database.write { db in
        switch row {
        case let .stop(id):
          try TripIdea.setBookingStatus(status, stopID: id, in: db)
        case let .stay(id):
          try TripStay.setBookingStatus(status, stayID: id, in: db)
        }
      }
    }
  }

  /// Dismiss the booking review before presenting the selected row's established
  /// editor — changing two sheet destinations in one transaction is unreliable.
  func editBookingItem(_ item: TripBookingItem) {
    switch item.row {
    case let .stop(id):
      guard let stop = plan.scheduled.first(where: { $0.id == id }) else { return }
      if stop.idea == nil {
        editFreeform(stop)
      } else {
        editStop(stop)
      }
    case let .stay(id):
      guard let stay = plan.stays.first(where: { $0.id == id }) else { return }
      editStay(stay)
    }
    queuedDestination = destination
    destination = nil
  }

  /// The booking review has fully dismissed, so its selected editor can appear.
  func bookingSheetDismissed() {
    guard let next = queuedDestination else { return }
    queuedDestination = nil
    destination = next
  }
}
