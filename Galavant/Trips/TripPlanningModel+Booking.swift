import Foundation
import GalavantSchema
import SQLiteData

extension TripPlanningModel {
  /// Commit the entry-scoped editor. A blank note clears the caption; turning off
  /// the reservation pin returns the stop to ordinary day-relative placement.
  func saveStop(_ draft: StopEditorDraft) {
    let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    withErrorReporting {
      try database.write { db in
        try TripIdea.setInlineNote(stopID: draft.stopID, note: note, in: db)
        if let status = draft.booking.statusToWrite {
          try TripIdea.setBookingStatus(status, stopID: draft.stopID, in: db)
        }
        if calendarTimeAuthority(for: draft.stopID) == .manual {
          try TripIdea.setPinnedReservation(
            reservationPin(from: draft.booking), stopID: draft.stopID, in: db)
        }
        let details = bookingDetails(from: draft.booking)
        try TripIdea.setBookingDetails(
          confirmationNumber: details.confirmationNumber,
          bookingURL: details.bookingURL,
          partySize: details.partySize,
          stopID: draft.stopID,
          in: db)
      }
    }
    destination = nil
  }

  func bookingFields(for stop: ResolvedStop) -> BookingFieldsDraft {
    let resolved = stop.entry.resolvedBooking(idea: stop.idea)
    return BookingFieldsDraft(
      explicitStatus: stop.entry.bookingStatus,
      resolvedStatus: resolved.status,
      source: resolved.source,
      isPinned: stop.entry.pinnedDate != nil,
      date: stop.entry.pinnedDate
        ?? stop.entry.schedule.dayNumber.flatMap { trip?.date(forDay: $0) }
        ?? date(),
      confirmationNumber: stop.entry.confirmationNumber ?? "",
      bookingURL: stop.entry.bookingURL ?? "",
      partySize: stop.entry.partySize.map(String.init) ?? "")
  }

  func bookingFields(for stay: TripStay) -> BookingFieldsDraft {
    let resolved = stay.resolvedBooking
    return BookingFieldsDraft(
      explicitStatus: stay.bookingStatus,
      resolvedStatus: resolved.status,
      source: resolved.source,
      confirmationNumber: stay.confirmationNumber ?? "",
      bookingURL: stay.bookingURL ?? "")
  }

  func reservationPin(from booking: BookingFieldsDraft) -> ReservationPin? {
    guard booking.isPinned else { return nil }
    return ReservationPin(date: booking.date)
  }

  func bookingDetails(from booking: BookingFieldsDraft) -> BookingDetails {
    let confirmation = booking.confirmationNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = booking.bookingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return BookingDetails(
      confirmationNumber: confirmation.isEmpty ? nil : confirmation,
      bookingURL: url.isEmpty ? nil : url,
      partySize: Int(booking.partySize.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  /// Commit the lodging editor while keeping booking fields independent of dates.
  func saveStay(_ draft: StayDraft) {
    guard let tripID = trip?.id else { return }
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedNote = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    let note = trimmedNote.isEmpty ? nil : trimmedNote
    withErrorReporting {
      try database.write { db in
        var savedStayID: TripStay.ID?
        if let stayID = draft.stayID {
          savedStayID = stayID
          try TripStay.edit(
            stayID: stayID, ideaID: draft.ideaID,
            title: title.isEmpty ? nil : title, note: note,
            checkInDay: draft.checkInDay, checkOutDay: draft.checkOutDay,
            checkInTime: draft.checkInTime, checkOutTime: draft.checkOutTime,
            plannedCheckInTime: draft.plannedCheckInTime,
            plannedCheckOutTime: draft.plannedCheckOutTime, in: db)
        } else if let ideaID = draft.ideaID {
          let stayID = try TripStay.create(
            tripID: tripID, ideaID: ideaID, note: note,
            checkInDay: draft.checkInDay, checkOutDay: draft.checkOutDay,
            checkInTime: draft.checkInTime, checkOutTime: draft.checkOutTime,
            plannedCheckInTime: draft.plannedCheckInTime,
            plannedCheckOutTime: draft.plannedCheckOutTime, in: db)
          savedStayID = stayID
          // A hotel is represented by its stay, not as an extra ordinary stop.
          try TripIdea
            .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
            .delete()
            .execute(db)
        } else {
          guard !title.isEmpty else { return }
          savedStayID = try TripStay.createFreeform(
            tripID: tripID, title: title, note: note,
            checkInDay: draft.checkInDay, checkOutDay: draft.checkOutDay,
            checkInTime: draft.checkInTime, checkOutTime: draft.checkOutTime,
            plannedCheckInTime: draft.plannedCheckInTime,
            plannedCheckOutTime: draft.plannedCheckOutTime, in: db)
        }
        if let stayID = savedStayID {
          if let status = draft.booking.statusToWrite {
            try TripStay.setBookingStatus(status, stayID: stayID, in: db)
          }
          let details = bookingDetails(from: draft.booking)
          try TripStay.setBookingDetails(
            confirmationNumber: details.confirmationNumber,
            bookingURL: details.bookingURL,
            stayID: stayID,
            in: db)
        }
      }
    }
    destination = nil
  }

  func toggleBookingStatus(for stop: ResolvedStop) {
    let resolved = stop.entry.resolvedBooking(idea: stop.idea)
    let status: BookingStatus =
      resolved.source == .explicit && resolved.status == .booked ? .toBook : .booked
    withErrorReporting {
      try database.write { db in
        try TripIdea.setBookingStatus(status, stopID: stop.id, in: db)
      }
    }
  }
}
