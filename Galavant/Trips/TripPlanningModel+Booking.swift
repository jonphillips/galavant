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
}
